#!/usr/bin/env ruby -rbundler/setup -rpry
# frozen_string_literal: true

require "diff/lcs"
require_relative "patches"
require_relative "debug"

using VDOM::Debug::Refinements

module VDOM
  class TextDiff
    def self.diff(node_id, seq1, seq2, &)
      # NOTE: This implementation is buggy.
      # Indexes and counts are incorrect sometimes.
      offset = 0

      ai = bj = 0
      res = String.new

      Diff::LCS.diff(seq1, seq2).each do |changeset|
        insertions = String.new

        ais = ai
        bjs = bj

        changeset.each do |change|
          case
          when change.deleting?
            while ai < change.position
              res << seq1[ai, 1]
              ai += 1
              bj += 1
            end

            ai += 1

          when change.adding?
            while bj < change.position
              res << seq1[ai, 1]
              ai += 1
              bj += 1
            end

            bj += 1

            res << change.element
          end

          d(res:)
        end

        deleting = changeset.select(&:deleting?)
        adding = changeset.select(&:adding?)

        d(ai:, ais:, deleting:)
        d(bj:, bjs:, adding:)
        ax = ai - ais
        bx = bj - bjs
        dx = bx - ax
        d(ax:, bx:, dx:)
        # d(offset:)
        replacement = adding.map(&:element).join
        deletion = deleting.map(&:element).join

        if deleting.empty?
          start = adding.map(&:position).min # + (bjs - ais).abs

          next yield Patches::InsertData[
            node_id,
            start,
            replacement
          ]
        end

        if adding.empty?
          start = bj # deleting.map(&:position).min # + (bjs - ais).abs

          next yield Patches::DeleteData[
            node_id,
            start,
            deletion.length
          ]
        end

        start = adding.map(&:position).min  #+ (bjs - ais).abs

        yield Patches::ReplaceData[
          node_id,
          start,
          deletion.length,
          replacement
        ]
      ensure
        d()
      end

      while ai < seq1.length
        res << seq1[ai, 1]
        ai += 1
        bj += 1
      end

      d(res:)
      seq2
    end
  end
end

if __FILE__ == $0
  require "minitest/autorun"

  class VDOM::TextDiff::Test < Minitest::Test
    def test_diff
      VDOM::Debug.disable do
        assert_diffed("foobar", "")
        assert_diffed("", "foobar")
        assert_diffed("foo", "foobar")
        assert_diffed("foobar", "foo")
        assert_diffed("foobaz", "foobarbaz")
        assert_diffed("foobaz", "foobarbaz")
      end
      assert_diffed("tjosannnnn", "tjohejannnn")
    end

    def test_diff_random
      10.times do
        words =
          File.join(__dir__, "..", "..", "app", "words.txt")
            .then { File.read(_1) }
            .split.shuffle
            .first(20)
            .map(&:strip)

        words.reduce("") do |seq1, seq2|
          assert_diffed(seq1, seq2)
        end
      end
    end

    def assert_diffed(seq1, seq2)
      actual = diff_and_patch(seq1, seq2)
      assert_equal(seq2, actual)
      actual
    end

    def diff_and_patch(seq1, seq2)
      result = seq1.dup

      if VDOM::Debug.enabled?
        puts "\e[3m #{__method__}(#{seq1.inspect}, #{seq2.inspect}) \e[0m"
      end

      VDOM::TextDiff.diff(nil, seq1, seq2) do |patch|
        d(patch:)
        d(before: result)

        case patch
        in VDOM::Patches::InsertData[offset:, data:]
          result.insert(offset, data)
        in VDOM::Patches::ReplaceData[offset:, count:, data:]
          result[offset...(offset + count)] = data
        in VDOM::Patches::DeleteData[offset:, count:]
          result[offset...(offset + count)] = ""
        end
        d(after: result)
      end

      d(expected: seq2)
      d(actual: result)
      d()

      result
    end
  end
end
