# frozen_string_literal: true

module VDOM
  class InvalidDescriptor < StandardError
  end

  Descriptor = Data.define(:type, :key, :slot, :children, :props, :hash) do
    def self.[](type, *children, key: nil, slot: nil, **props) =
      new(
        type,
        key,
        slot,
        normalize_children(children),
        props,
        calculate_hash(type, key, slot, props),
      )

    def self.calculate_hash(type, key, slot, props) =
      [
        type,
        key,
        slot,
        type == :input && props[:type],
      ].hash

    def self.same?(a, b) = get_hash(a) == get_hash(b)

    def self.get_hash(descriptor) =
      case descriptor
      in Descriptor then descriptor.hash
      in String then String.hash
      in Array then Array.hash
      else descriptor.hash
      end

    def self.normalize_children(children) =
      Array(children)
        .flatten
        .map { or_string(_1) }
        .compact

    def self.or_string(descriptor)
      case descriptor
      in ^(self)
        descriptor
      in Reactively::API::Readable
        descriptor
      else
        (descriptor && descriptor.to_s) || nil
      end
    end

    def eql?(other) =
      self.class === other && hash == other.hash
    def with_children(children) =
      with(children: self.class.normalize_children(children))
    def update_props(&) =
      with(props: yield(props))
  end
end
