require "singleton"
require "brotli"

module VDOM
  class Assets
    IntegrityHash = Data.define(:raw, :bitlen) do
      def self.[](content, bitlen = 256) =
        new(Digest::SHA2.digest(content, bitlen), bitlen)

      def to_s =
        "sha#{bitlen}-#{base64}"
      def base64 =
        Base64.strict_encode64(raw)
      def urlsafe_base64 =
        Base64.urlsafe_encode64(raw, padding: false)
    end

    EncodedContent = Data.define(:encoding, :to_s) do
      def self.[](content, mime_type) =
        case mime_type.media_type
        in "text"
          new(:br, Brotli.deflate(content))
        else
          new(nil, content)
        end
    end

    Content = Data.define(:encoded, :integrity, :mime_type) do
      def self.[](content, mime_type) =
        new(
          EncodedContent[content, mime_type],
          IntegrityHash[content],
          mime_type,
        )

      def encoding =
        encoded.encoding
      def to_s =
        encoded.to_s
      def type =
        mime_type.to_s
      def preferred_extension =
        mime_type.preferred_extension
    end

    Asset = Data.define(:filename, :content) do
      def self.[](content, mime_type) =
        Content[content, mime_type].then do |content|
          new(filename_from_content(content), content)
        end

      def self.filename_from_content(content) =
        "#{content.integrity.urlsafe_base64}.#{content.preferred_extension}"

      def path =
        filename
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
