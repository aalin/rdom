# frozen_string_literal: true

module VDOM
  module Patches
    CreateRoot = Data.define(:session_id)
    DestroyRoot = Data.define()

    CreateElement = Data.define(:id, :type)
    CreateDocumentFragment = Data.define(:id)
    CreateTextNode = Data.define(:id, :content)
    CreateCommentNode = Data.define(:id, :content)

    InsertBefore = Data.define(:parent_id, :id, :ref_id)
    RemoveChild = Data.define(:parent_id, :id)
    RemoveNode = Data.define(:id)

    SetAttribute = Data.define(:id, :name, :value)
    RemoveAttribute = Data.define(:id, :name)

    SetHandler = Data.define(:id, :name, :handler_id)
    RemoveHandler = Data.define(:id, :name, :handler_id)

    SetCSSProperty = Data.define(:id, :name, :value)
    RemoveCSSProperty = Data.define(:id, :name)

    SetTextContent = Data.define(:id, :content)
    ReplaceData = Data.define(:id, :offset, :count, :data)
    InsertData = Data.define(:id, :offset, :data)
    DeleteData = Data.define(:id, :offset, :size)

    Ping = Data.define(:time)

    def self.serialize(patch)
      [patch.class.name[/[^:]+\z/], *patch.deconstruct]
    end
  end
end