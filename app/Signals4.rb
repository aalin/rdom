WORDS = File.read(File.join(__dir__, "words.txt")).split.sort

def measure
  start_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
ensure
  duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_at
  Console.logger.info(caller.first, "duration: #{duration}")
end

def render
  puts "\e[31mRendering #{__FILE__}\e[0m"

  search = signal("")

  words = computed do
    value = search.value.strip
    WORDS.select { _1.start_with?(value) }.first(20)
  end

  list = computed do
    H[:ul, words.value.map { |key| H[:li, key, key:] }]
  end

  longest_word = computed do
    words.value.sort_by(&:length).last.to_s
  end

  joined = computed do
    words.value.join(" ")
  end

  oninput = ->(target:, **) do
    search.value = target[:value]
  end

  H[:article,
    H[:input, type: "text", oninput:],
    H[:pre, "Longest word: ", longest_word],
    H[:div,
      list,
      H[:p, joined],
      style: { display: "flex", gap: "1em" }
    ]
  ]
end
