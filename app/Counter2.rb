def render
  puts "\e[31mRendering #{__FILE__}\e[0m"

  count = signal(0)

  handler = ->(target:, **) do
    count.value = target[:value].to_i
  end

  H[:article,
    H[:h2, "Counter"],
    H[:p, "Current count: ", H[:output, count]],
    H[:p,
      H[:input,
        type: "number",
        min: 0,
        step: 1,
        value: count,
        onchange: handler,
        oninput: handler,
      ],
    ],
    H[:p,
      H[:button,
        "Increment",
        onclick: ->{ count.value += 1 },
        style: { padding: "1em" }
      ],
      H[:button,
        "Decrement",
        onclick: ->{ count.value -= 1 },
        style: { padding: "1em" }
      ],
      H[:button,
        "Reset",
        onclick: ->{ count.value = 0 },
        style: { padding: "1em" }
      ],
      style: {
        display: "flex",
        gap: "1em",
      }
    ],
    style: {
      border: "1px solid #000",
      padding: "0 1em",
    }
  ]
end
