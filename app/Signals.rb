def initialize
  @count = signal(0)

  @is_even = computed do
    (@count.value % 2).zero?
  end

  @message = computed do
    if @is_even.value
      "The value is even"
    else
      "Odd"
    end
  end
end

def render
  puts "\e[31mRendering #{__FILE__}\e[0m"

  H[:article,
    H[:p, "Count: ", @count],
    H[:button, "Increment", onclick: ->(){ @count.value += 1 }],
    H[:p, "Message: ", @message]
  ]
end
