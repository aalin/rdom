MAX_WORD_LENGTH = 32
INITIAL_VALUE = "Enter text here"

def render
  puts "\e[31mRendering #{__FILE__}\e[0m"

  input = signal(INITIAL_VALUE)

  output = computed do
    input
      .value
      .split(" ")
      .map do |word|
        if word.length < MAX_WORD_LENGTH
          next word
        end

        word
          .grapheme_clusters
          .each_slice(MAX_WORD_LENGTH)
          .map(&:join)
          .to_a
      end
      .join(" ")
  end

  H[:article,
    H[:div,
      H[:textarea,
        oninput: ->(target:, **) do
          input.value = target[:value]
        end,
        initialValue: INITIAL_VALUE,
        style: {
          flex: [1, 1],
          max_width: 36.em,
          min_width: 8.em,
          font: "inherit",
        },
      ],
      H[:pre,
        output,
        style: {
          white_space: "pre-wrap",
          background: "#0001",
          border: [1.px, "solid", "#0001"],
          flex: [1, 1],
          max_width: 36.em,
          min_width: 8.em,
        },
      ],
      style: {
        display: "flex",
        flex_wrap: "wrap",
        justify_content: "center",
        gap: 1.em,
        padding: [0, 1.em],
        margin: [0, :auto],
      }
    ]
  ]
end
