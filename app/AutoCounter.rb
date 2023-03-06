Article = import("Article.rb")

def initialize
  @count = 0
end

def mount
  loop do
    sleep 0.5
    @count += 1
  end
end

def handle_click(**)
  @count = 0
end

def render
  H[:article,
    H[:h2, "Auto count"],
    H[:p, "Current count: ", H[:output, @count]],
    H[:p,
      H[:button,
        H[:span, "Click me!"],
        onclick: method(:handle_click),
        style: {
          background: "hsl(%.1fturn 100%% 50%%)" % (@count / 100.0 * Math::PI),
          transition: "background .25s",
          padding: "1em",
        }
      ],
    ],
  ]
end
