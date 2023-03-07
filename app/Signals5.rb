MAX_WORD_LENGTH = 32
INITIAL_VALUE = "Enter text here"

def render
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
      ],
      H[:pre,
        output,
        style: {
          white_space: "pre-wrap",
          background: "#0001",
          border: "1px solid #0003",
        }
      ],
      style: {
        display: "flex",
        flex_direction: "column",
        padding: "0 1em",
        margin: "0 auto",
        max_width: "36em",
      }
    ]
  ]
end
