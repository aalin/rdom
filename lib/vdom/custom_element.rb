module VDOM
  CustomElement = Data.define(:name, :template, :stylesheet) do
    def filename =
      "#{name}.html"
    def content =
      "#{stylesheet&.import_html}#{template}"
  end
end
