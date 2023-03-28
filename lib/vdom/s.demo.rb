require "bundler/setup"
require_relative "s"

Async do
  S.root do
    a = S.signal(0)
    b = S.signal(0)

    c = S.computed do
      p(a.value + b.value)
    end

    d = S.computed do
      if a.value == 2
        p(b2: b.value * 2)
      else
        p(a2: a.value * 2)
      end
    end

    e = S.effect do
      p(e: c.value)
    end

    f = S.effect do
      p(f: d.value)
    end

    puts
    sleep 0.1
    puts
    puts "**** INCREMENTING A"
    a.value += 1
    puts "**** INCREMENTED A"
    sleep 0.1
    puts

    puts "**** INCREMENTING B"
    b.value += 1
    puts "**** INCREMENTED B"
    sleep 0.1
    puts

    puts "**** INCREMENTING A"
    a.value += 1
    puts "**** INCREMENTED A"
    sleep 0.1
    puts

    puts "**** INCREMENTING B"
    b.value += 1
    puts "**** INCREMENTED B"
    sleep 0.1
    puts

    puts "**** INCREMENTING B"
    b.value += 1
    puts "**** INCREMENTED B"
    sleep 0.1
    puts

    puts "**** INCREMENTING A AND B"
    S.batch do
      a.value += 1
      b.value += 1
    end
    puts "**** INCREMENTED A AND B"
    sleep 0.1
    puts

    puts "**** INCREMENTING B"
    b.value += 1
    puts "**** INCREMENTED B"
    sleep 0.1
    puts

    Async::Task.current.stop
  end

  def assert_equal(a, b)
    unless a == b
      raise "#{a.inspect} does not equal #{b.inspect}"
    end
  end

  S.root do
    a = S.signal("a")
    called_times = 0

    b =
      S.computed do
        a.value
        "foo"
      end

    c = S.computed do
      puts "CALCULATING C"
      called_times += 1
      b.value
    end

    assert_equal("foo", c.value)
    sleep 0.1
    assert_equal(1, called_times)

    a.value = "aa"
    sleep 0.1
    assert_equal("foo", c.value)
    assert_equal(1, called_times)
  end
end
