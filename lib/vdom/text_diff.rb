#!/usr/bin/env ruby -rbundler/setup
# frozen_string_literal: true

require "diff/lcs"
require_relative "patches"

module VDOM
  class TextDiff
    def self.diff(node_id, seq1, seq2, &)
      # NOTE: This implementation is buggy.
      # Indexes and counts are incorrect sometimes.
      Diff::LCS.diff(seq1, seq2).each do |changes|
        deleting = changes.select(&:deleting?)
        inserting = changes.reject(&:deleting?)
        replacement = inserting.map(&:element).join
        deletion = deleting.map(&:element).join

        if deleting.empty?
          next yield Patches::InsertData[
            node_id,
            inserting.map(&:position).min,
            replacement
          ]
        end

        if inserting.empty?
          next yield Patches::DeleteData[
            node_id,
            deleting.map(&:position).min,
            deleting.map(&:position).max - deleting.map(&:position).min,
          ]
        end

        yield Patches::ReplaceData[
          node_id,
          inserting.map(&:position).min,
          deletion.length,
          replacement
        ]
      end

      seq2
    end
  end
end

if __FILE__ == $0
  require "minitest/autorun"

  class VDOM::TextDiff::Test < Minitest::Test
    def test_diff
      assert_diffed("foobar", "")
      assert_diffed("", "foobar")
      assert_diffed("foo", "foobar")
      assert_diffed("foobar", "foo")
      assert_diffed("foobaz", "foobarbaz")
      assert_diffed("foobaz", "foobarbaz")
      assert_diffed("tjosannnnn", "tjohejsannnn")
    end

    def assert_diffed(seq1, seq2)
      assert_equal(seq2, diff_and_patch(seq1, seq2))
    end

    def diff_and_patch(seq1, seq2)
      result = seq1.dup

      VDOM::TextDiff.diff(nil, seq1, seq2) do |patch|
        case patch
        in VDOM::Patches::InsertData[offset:, data:]
          result.insert(offset, data)
        in VDOM::Patches::ReplaceData[offset:, count:, data:]
          result[offset...(offset + count)] = data
        in VDOM::Patches::DeleteData[offset:, size:]
          result[offset..(offset + size)] = ""
        end
      end

      result
    end
  end
end
