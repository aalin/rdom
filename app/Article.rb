def render
  H[:article,
    H[:slot],
    style: {
      border: "1px solid #000",
      padding: "0 1em",
    }
  ]
end
