require "singleton"

module VDOM
  class Assets
    include Singleton

    def initialize =
      @files = {}
    def store(asset) =
      @files.store(asset.filename, asset)
    def fetch(filename, &) =
      @files.fetch(filename, &)
  end
end
