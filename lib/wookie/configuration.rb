module Wookie
  class Configuration

    extend Forwardable
    def_delegators :@hash, :to_hash, :[], :[]=, :==, :fetch, :delete, :has_key?, :merge!

    DEFAULTS = {
      amqp_heartbeat: 10
    }.freeze

    def initialize
      @hash = DEFAULTS.dup
      @hash[:amqp]  ||= ENV.fetch('RABBITMQ_URL', 'amqp://guest:guest@localhost:5672')
      @hash[:vhost] ||= AMQ::Settings.parse_amqp_url(@hash[:amqp]).fetch(:vhost, '/')
    end
  end
end
