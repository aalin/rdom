# frozen_string_literal: true

module VDOM
  module Patches
    CreateRoot = Data.define()
    DestroyRoot = Data.define()

    CreateElement = Data.define(:id, :type)
    CreateDocumentFragment = Data.define(:id)
    CreateTextNode = Data.define(:id, :content)
    CreateCommentNode = Data.define(:id, :content)

    InsertBefore = Data.define(:parent_id, :id, :ref_id)
    RemoveChild = Data.define(:parent_id, :id)
    RemoveNode = Data.define(:id)

    DefineCustomElement = Data.define(:name, :template, :stylesheet_path)
    AssignSlot = Data.define(:parent_id, :name, :node_ids)

    CreateChildren = Data.define(:parent_id, :slot_id)
    RemoveChildren = Data.define(:slot_id)
    ReorderChildren = Data.define(:slot_id, :child_ids)

    SetAttribute = Data.define(:parent_id, :ref_id, :name, :value)
    RemoveAttribute = Data.define(:parent_id, :ref_id, :name)

    SetHandler = Data.define(:parent_id, :ref_id, :name, :handler_id)
    RemoveHandler = Data.define(:parent_id, :ref_id, :name, :handler_id)

    SetCSSProperty = Data.define(:parent_id, :ref_id, :name, :value)
    RemoveCSSProperty = Data.define(:parent_id, :ref_id, :name)

    SetTextContent = Data.define(:id, :content)
    ReplaceData = Data.define(:id, :offset, :count, :data)
    InsertData = Data.define(:id, :offset, :data)
    DeleteData = Data.define(:id, :offset, :count)

    Ping = Data.define(:time)

    def self.serialize(patch)
      [patch.class.name[/[^:]+\z/], *patch.deconstruct]
    end
  end
end
