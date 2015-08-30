require "wookie/version"
require "wookie/configuration"
require "wookie/exceptions"
require "thread/pool"
require "bunny"
require "logger"
require "serverengine"

module Wookie
  def self.configure(opts={})
    @@config.merge!(opts)
  end

  def self.config
    @@config ||= Configuration.new
  end
end

require "wookie/worker"
