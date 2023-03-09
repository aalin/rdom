Item = Data.define(:value) do
  def id = object_id
  def to_s = value.to_s
end

INITIAL_ITEMS = %w[0 1 2 3 4 5 6 7 8 9].map { Item[_1] }.freeze

def render
  puts "\e[31mRendering #{__FILE__}\e[0m"

  input = signal("")
  items = signal(INITIAL_ITEMS)

  oninput = ->(target:, **) do
    input.value = target[:value].to_s.strip
  end

  prepend = -> do
    break if input.value.empty?
    items.value = [Item[input.value], *items.value]
    input.value = ""
  end

  append = -> do
    break if input.value.empty?
    items.value = [*items.value, Item[input.value]]
    input.value = ""
  end

  sort = -> { items.value = items.value.sort_by(&:value) }
  shuffle = -> { items.value = items.value.shuffle }
  reverse = -> { items.value = items.value.reverse }
  clear = -> { items.value = [] }

  list = computed do
    H[:ul,
      items.value.map { H[:li, _1, key: _1.id] },
      style: {
        border: [1.px, "solid", "#000"]
      }
    ]
  end

  joined = computed do
    H[:pre,
      items.value
        .map(&:inspect)
        .join("\n")
  ]
  end

  H[:article,
    H[:div,
      H[:p, "This page shows that nodes aren't reordered properly."],
      H[:fieldset,
        H[:legend, "Add"],
        H[:div,
          H[:input, type: "text", oninput:, autocomplete: "off", value: input],
          H[:button, "Prepend", onclick: prepend],
          H[:button, "Append", onclick: append],
          style: {
            display: "flex",
            gap: 1.em,
          }
        ],
      ],
      H[:fieldset,
        H[:legend, "Actions"],
        H[:div,
          H[:button, "Sort", onclick: sort],
          H[:button, "Reverse", onclick: reverse],
          H[:button, "Shuffle", onclick: shuffle],
          H[:button, "Clear", onclick: clear],
          style: {
            display: "flex",
            gap: 1.em,
          }
        ]
      ],
      style: {
        display: "flex",
        flex_wrap: "wrap",
      }
    ],
    H[:div,
      H[:div, list, style: { flex_basis: 30.percent }],
      H[:div,
        H[:p, "The order in the list should match this order:"],
        joined,
      ],
      style: {
        display: "grid",
        grid_template_columns: [30.percent, "auto"],
        gap: 1.em,
      }
    ]
  ]
end
