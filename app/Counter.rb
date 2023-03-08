def initialize
  @count = 0
end

def handle_click(**)
  @count += 1
end

def handle_change(target:, **)
  @count = target[:value].to_i
end

def render
  puts "\e[31mRendering #{__FILE__}\e[0m"

  H[:article,
    H[:h2, "Counter"],
    H[:p, "Current count: ", H[:output, @count]],
    H[:p,
      H[:input,
        type: "number",
        min: 0,
        step: 1,
        value: @count,
        onchange: method(:handle_change)
      ],
    ],
    H[:p,
      H[:button,
        H[:span, "Click me!"],
        onclick: method(:handle_click),
        style: {
          background: "hsl(%.2fturn 100%% 50%%)" % (@count / 100.0),
          padding: 1.em,
        }
      ],
    ],
    style: {
      border: [1.px, "solid", "#000"],
      padding: [0, 1.em],
    }
  ]
end
