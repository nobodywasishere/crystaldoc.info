module CrystalDoc
  class RateLimiter
    private class Bucket
      getter tokens : Float64
      getter last_refill : Time
      getter max_tokens : Float64
      getter refill_rate : Float64

      def initialize(@max_tokens : Float64, @refill_rate : Float64)
        @tokens = max_tokens
        @last_refill = Time.utc
      end

      def allow? : Bool
        now = Time.utc
        elapsed = (now - @last_refill).total_seconds
        @tokens = Math.min(@max_tokens, @tokens + elapsed * @refill_rate)
        @last_refill = now

        if @tokens >= 1.0
          @tokens -= 1.0
          true
        else
          false
        end
      end
    end

    getter buckets = {} of String => Bucket
    getter max_tokens : Float64
    getter refill_rate : Float64
    @mutex : Mutex

    def initialize(@max_tokens : Float64 = 60.0, @refill_rate : Float64 = 1.0)
      @mutex = Mutex.new
      spawn(same_thread: true) { cleanup_loop }
    end

    def allow?(key : String) : Bool
      @mutex.synchronize do
        bucket = @buckets[key] ||= Bucket.new(@max_tokens, @refill_rate)
        bucket.allow?
      end
    end

    private def cleanup_loop
      loop do
        sleep 60.seconds
        now = Time.utc
        @mutex.synchronize do
          @buckets.reject! { |_, b| (now - b.last_refill).total_seconds > 300 }
        end
      end
    end
  end
end
