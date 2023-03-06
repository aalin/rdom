StartPage = import("StartPage.rb")
Counter = import("Counter.rb")
Counter2 = import("Counter2.rb")
AutoCounter = import("AutoCounter.rb")
Signals = import("Signals.rb")
Signals2 = import("Signals2.rb")
Signals3 = import("Signals3.rb")
Signals4 = import("Signals4.rb")

PAGES = [
  StartPage,
  Counter,
  Counter2,
  AutoCounter,
  Signals,
  Signals2,
  Signals3,
  Signals4,
]

def initialize(**)
  @page = PAGES.first
end

def render
  H[:section,
    H[:header,
      H[:h1, "My webpage"]
    ],
    H[:nav,
      H[:menu,
        PAGES.map do |component|
          H[:li,
            H[:button,
              component.title,
              onclick: ->() { @page = component },
              style: {
                border: 0,
                padding: 0,
                margin: 0,
                background: "transparent",
                font_family: "inherit",
                font_size: "1.2em",
                cursor: "pointer",
                text_decoration: "underline",
                font_weight: @page == component ? "bold" : "normal"
              },
            ],
            key: component.hash,
            style: {
              margin: 0,
              padding: 0,
            }
          ]
        end,
        style: {
          list_style_type: "none",
          display: "flex",
          margin: "1em 0",
          padding: "1em",
          gap: ".5em",
          border_radius: "2px",
          background: "#0003",
        }
      ]
    ],
    H[@page]
  ]
end