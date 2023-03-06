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
