def render
  H[:div,
    H[:h3, H[:slot, name: "title"]],
    H[:div, H[:slot], class: "body"],
    class: "card",
  ]
end
