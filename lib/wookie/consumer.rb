require 'bunny'

module Wookie
  class Consumer < Bunny::Consumer
    def cancelled?
      @cancelled
    end

    def handle_cancellation(_)
      @cancelled = true
    end
  end
end
