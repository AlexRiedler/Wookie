module Wookie
  class OneshotHandler
    def initialize(channel, queue, opts)
      @channel = channel
      @queue = queue
      @opts = opts
    end

    def work(payload, delivery_info, metadata)
      res, error = yield
      if res == :error
        self.send(res, payload, delivery_info, metadata, error)
      elsif self.respond_to?(res)
        self.send(res, payload, delivery_info, metadata)
      else
        self.noop(payload, delivery_info, metadata)
      end
    end

    def ack(payload, delivery_info, metadata)
      @channel.acknowledge(delivery_info.delivery_tag, false)
    end

    def timeout(payload, delivery_info, metadata)
      reject(payload, delivery_info, metadata)
    end

    def error(payload, delivery_info, metadata, error)
      reject(payload, delivery_info, metadata)
    end

    def reject(payload, delivery_info, metadata)
      @channel.reject(delivery_info.delivery_tag, false)
    end

    def requeue(payload, delivery_info, metadata)
      @channel.reject(delivery_info.delivery_tag, true)
    end

    def noop(payload, delivery_info, metadata)
    end
  end

  # This class is taken from jondot's Sneakers,
  # modified for interface change reasons
  #
  # Maxretry uses dead letter policies on Rabbitmq to requeue and retry
  # messages after failure (rejections, errors and timeouts). When the maximum
  # number of retries is reached it will put the message on an error queue.
  # This handler will only retry at the queue level. To accomplish that, the
  # setup is a bit complex.
  #
  # Input:
  #   worker_exchange (eXchange)
  #   worker_queue (Queue)
  # We create:
  #   worker_queue-retry - (X) where we setup the worker queue to dead-letter.
  #   worker_queue-retry - (Q) queue bound to ^ exchange, dead-letters to
  #                        worker_queue-retry-requeue.
  #   worker_queue-error - (X) where to send max-retry failures
  #   worker_queue-error - (Q) bound to worker_queue-error.
  #   worker_queue-retry-requeue - (X) exchange to bind worker_queue to for
  #                                requeuing directly to the worker_queue.
  #
  # This requires that you setup arguments to the worker queue to line up the
  # dead letter queue. See the example for more information.
  #
  # Many of these can be override with options:
  # - retry_exchange - sets retry exchange & queue
  # - retry_error_exchange - sets error exchange and queue
  # - retry_requeue_exchange - sets the exchange created to re-queue things
  #   back to the worker queue.
  #
  class MaxRetryHandler < DefaultHandler
    def initialize(channel, queue, opts)
      super(channel, queue, opts)
      @queue_name = queue.name
      retry_name = @opts[:retry_exchange] || "#{@queue_name}-retry"
      error_name = @opts[:retry_error_exchange] || "#{@queue_name}-error"
      requeue_name = @opts[:retry_requeue_exchange] || "#{@queue_name}-retry-requeue"

      @retry_exchange, @error_exchange, @requeue_exchange =
        [retry_name, error_name, requeue_name].map do |name|
          @channel.exchange(name, type: 'topic', durable: @opts[:durable])
        end

      @retry_queue =
        @channel.queue(
          retry_name,
          durable: opts[:durable],
          arguments: {
            :'x-dead-letter-exchange' => requeue_name,
            :'x-message-ttl' => @opts[:retry_timeout] || 60_000
          }
      )
      @retry_queue.bind(@retry_exchange, routing_key: '#')

      @error_queue = @channel.queue(error_name, durable: opts[:durable])
      @error_queue.bind(@error_exchange, :routing_key => '#')

      # Finally, bind the worker queue to our requeue exchange
      @queue.bind(@requeue_exchange, :routing_key => '#')

      @max_retries = @opts[:retry_max_times] || 5
    end

    def work(payload, delivery_info, metadata)
      res, error = yield
      if res == :error
        self.send(res, payload, delivery_info, metadata, error)
      elsif self.respond_to?(res)
        self.send(res, payload, delivery_info, metadata)
      else
        self.noop(payload, delivery_info, metadata)
      end
    end

    def ack(payload, delivery_info, metadata)
      @channel.acknowledge(delivery_info.delivery_tag, false)
    end

    def timeout(payload, delivery_info, metadata)
      handle_retry(payload, delivery_info, metadata)
    end

    def error(payload, delivery_info, metadata, error)
      handle_retry(payload, delivery_info, metadata, error)
    end

    def reject(payload, delivery_info, metadata)
      handle_retry(payload, delivery_info, metadata, :reject)
    end

    def requeue(payload, delivery_info, metadata)
      @channel.reject(delivery_info.delivery_tag, true)
    end

    def noop(payload, delivery_info, metadata)
    end

    # Helper logic for retry handling. This will reject the message if there
    # are remaining retries left on it, otherwise it will publish it to the
    # error exchange along with the reason.
    # @param delivery_info [Bunny::DeliveryInfo]
    # @param metadata [Bunny::MessageProperties]
    # @param payload [String] The message
    # @param reason [String, Symbol, Exception] Reason for the retry, included
    #   in the JSON we put on the error exchange.
    def handle_retry(payload, delivery_info, metadata, reason)
      # +1 for the current attempt
      num_attempts = failure_count(metadata[:headers]) + 1
      if num_attempts <= @max_retries
        # We call reject which will route the message to the
        # x-dead-letter-exchange (ie. retry exchange) on the queue
        @channel.reject(delivery_info.delivery_tag, false)
        # TODO: metrics
      else
        # Retried more than the max times
        # Publish the original message with the routing_key to the error exchange
        data = {
          error: reason,
          num_attempts: num_attempts,
          failed_at: Time.now.iso8601,
          payload: Base64.encode64(payload.to_s)
        }.tap do |hash|
          if reason.is_a?(Exception)
            hash[:error_class] = reason.class
            hash[:error_message] = "#{reason}"
            if reason.backtrace
              hash[:backtrace] = reason.backtrace.take(10).join(', ')
            end
          end
        end.to_json
        @error_exchange.publish(data, :routing_key => delivery_info.routing_key)
        @channel.acknowledge(delivery_info.delivery_tag, false)
        # TODO: metrics
      end
    end
    private :handle_retry

    # Uses the x-death header to determine the number of failures this job has
    # seen in the past. This does not count the current failure. So for
    # instance, the first time the job fails, this will return 0, the second
    # time, 1, etc.
    # @param headers [Hash] Hash of headers that Rabbit delivers as part of
    #   the message
    # @return [Integer] Count of number of failures.
    def failure_count(headers)
      if headers.nil? || headers['x-death'].nil?
        0
      else
        x_death_array = headers['x-death'].select do |x_death|
          x_death['queue'] == @worker_queue_name
        end
        if x_death_array.count > 0 && x_death_array.first['count']
          # Newer versions of RabbitMQ return headers with a count key
          x_death_array.inject(0) {|sum, x_death| sum + x_death['count']}
        else
          # Older versions return a separate x-death header for each failure
          x_death_array.count
        end
      end
    end
    private :failure_count
  end
end
