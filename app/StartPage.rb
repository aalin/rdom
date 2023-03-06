def self.title = "Start"

def render
  H[:article,
    H[:h2, "Start page"],
    H[:p, "This webpage is written in Ruby and updates are streamed to your browser via http/2 streams."]
  ]
end
