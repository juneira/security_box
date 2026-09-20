# frozen_string_literal: true

module SecurityBox
  class Error < StandardError; end

  class ImageMissing < Error; end

  class InvalidConfiguration < Error; end

  class PoolClosed < Error; end
end
