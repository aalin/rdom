require "singleton"
require "brotli"

module VDOM
  class Assets
    Asset = Data.define(:filename, :content, :content_type, :hash) do
      def self.[](content, content_type) =
        content_hash(content).then do |hash|
          new(
            filename(hash, content_type),
            Brotli.deflate(content),
            content_type,
            hash.hash
          )
        end
      def self.content_hash(content) =
        Base64.urlsafe_encode64(Digest::SHA256.digest(content), padding: false)
      def self.filename(hash, content_type) =
        "#{hash}.#{content_type.extensions.first}"

      def eql?(other) =
        other.hash == hash
      def path =
        "/.rdom/#{filename}"
      def content_encoding =
        "br"
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
