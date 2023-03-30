require "singleton"
require "brotli"

module VDOM
  class Assets
    ContentHash = Data.define(:type, :content_hash) do
      def self.[](content) =
        new(:sha384, Digest::SHA384.digest(content))

      def urlsafe_base64 =
        Base64.urlsafe_encode64(content_hash, padding: false)
      def base64 =
        Base64.strict_encode64(content_hash)
      def integrity =
        "#{type}-#{base64}"
    end

    EncodedContent = Data.define(:encoding, :content) do
      def self.[](content, mime_type)
        case mime_type.media_type
        in "text"
          new(:br, Brotli.deflate(content))
        else
          new(nil, content)
        end
      end
    end

    Asset = Data.define(:filename, :encoded_content, :mime_type, :content_hash) do
      def self.[](content, mime_type) =
        ContentHash[content].then do |content_hash|
          new(
            "#{content_hash.urlsafe_base64}.#{mime_type.preferred_extension}",
            EncodedContent[content, mime_type],
            mime_type,
            content_hash,
          )
        end

      def path =
        filename
      def content =
        encoded_content.content
      def content_encoding =
        encoded_content.encoding
      def content_type =
        mime_type.to_s
      def integrity =
        content_hash.integrity

      def hash =
        [self.class, content_hash].hash
      def eql?(other) =
        other.hash == hash
    end

    include Singleton

    def initialize =
      @files = {}
    def store(asset) =
      @files[asset.filename] ||= asset
    def fetch(filename, &) =
      @files.fetch(filename, &)
  end
end
