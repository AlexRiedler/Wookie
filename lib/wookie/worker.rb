require "wookie/handlers"
require "wookie/consumer"
require "wookie/exception"

module Wookie
  module Worker
    attr_reader :queue, :id, :opts

    MAX_INT = 2**31

    def self.included(base)
      base.extend ClassMethods
    end

    DEFAULTS = {
      # bunny connection
      connection: nil,

      # queue options
      durable: true,
      auto_delete: false,

      # channel options
      threads: 1,

      # consumer options
      no_ack: true,
      consumer_tag: "", # auto-generated
      exclusive: false,
      arguments: {},

      # job options
      job_timeout: 30, # seconds
      handler: nil, # custom response handler
    }

    def initialize(opts = {})
      @id = rand(MAX_INT).floor.to_s(36)
      @opts = DEFAULTS.merge(@opts)

      @bunny = @opts[:connection] || Wookie.create_bunny_connection
      @bunny.start unless @bunny.open?
      @channel = @opts[:channel] || @bunny.create_channel(nil, @opts[:threads])
      @queue = @bunny.queue(
        opts[:queue_name],
        manual_ack: @opts[:manual_ack],
        durable: @opts[:durable],
        auto_delete: @opts[:auto_delete]
      )
      @consumer = Wookie::Consumer.new(
        @channel,
        @queue,
        @opts[:consumer_tag],
        @opts[:no_ack],
        @opts[:exclusive],
        @opts[:arguments]
      )

      @job_timeout = opts[:job_timeout]
      @work_arity = instance_method(:work).arity
      @handler = opts.fetch(:handler) { Wookie::OneshotHandler }
    end

    def _work(payload, delivery_info, metadata)
      res = nil
      error = nil
      Thread.current[:msg_handler] ||= @handler.new(@channel, @queue, @opts)
      Thread.current[:msg_handler].work(payload, delivery_info, metadata) do
        begin
          Timeout.timeout(@job_timeout, Wookie::JobTimeout) do
            if @work_arity > 1
              res = work(msg, delivery_info, metadata)
            else
              res = work(msg)
            end
          end
          res
        rescue Wookie::JobTimeout
          res = :timeout
        rescue => e
          res = :error
          error = e
        end
        [res, error]
      end
    end

    def start
      @consumer.on_delivery do |delivery_info, metadata, payload|
        _work(payload, delivery_info, metadata)
      end
      @queue.subscribe_with(@consumer)
    end

    def stop
      @consumer.cancel
      @channel.close unless @opts[:channel]
      @bunny.close unless @opts[:connection]
    end

    module ClassMethods
      attr_reader :queue_opts
      attr_reader :queue_name

      def from_queue(q)
      end

      def enqueue(msg, exchange: :default_exchange)
        publisher.publish(msg, exchange)
      end
    end
  end
end
