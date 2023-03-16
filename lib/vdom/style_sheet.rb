# frozen_string_literal: true

module VDOM
  StyleSheet = Data.define(:filename, :content) do
    CONTENT_TYPE = "text/css"

    def content_type =
      CONTENT_TYPE

    def path =
      "/.rdom/#{filename}"

    def import_html =
      "<style>@import #{path.inspect};</style>"
  end
end
