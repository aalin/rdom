WORDS = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Curabitur faucibus nec quam id lacinia. In vulputate molestie est eu feugiat. Duis scelerisque tincidunt sodales. Curabitur vel nisl tellus. Aenean auctor malesuada feugiat. Morbi bibendum, lacus ut gravida vulputate, urna sapien sodales sapien, at tempor mi arcu non ante. Vestibulum sed fermentum elit, vel varius nunc.".split(/\b/).freeze

def render
  puts "\e[31mRendering #{__FILE__}\e[0m"

  count = signal(0)

  words = computed do
    WORDS.select { _1.length <= count.value }.join
  end

  H[:article,
    H[:button, "Update", onclick: ->(){ count.value += 1 }],
    H[:button, "Reset", onclick: ->(){ count.value = 0 }],
    H[:p, "Current value: ", H[:output, count]],
    H[:pre, words, style: { white_space: "pre-wrap", display: "inline-block", background: "#0003", border: "1px solid #0003" }],
  ]
end
