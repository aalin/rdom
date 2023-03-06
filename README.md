# rdom

Reactive DOM updates with Ruby.

🔥 live demo at [rdom.fly.dev](https://rdom.fly.dev/) 🚀

## Description

This is a very basic experiment.
For a more complete implementation,
see [Mayu Live](https://github.com/mayu-live/framework),
however, I had some ideas that I felt like I had to explore.

This program reads `app/MyComponent.rb` and performs the following transforms:

* Add `frozen_string_literal: true` to the top of the file.
* Transform `@foo` to `self.state[:foo]`.
* Transform `@foo = 123` to `self.update { self.state[:foo] = 123 }`.
* Transform `$foo` to `self.props[:foo]`.

Code within [backticks](https://ruby-doc.org/3.2.0/Kernel.html#method-i-60)
and [heredocs](https://ruby-doc.org/3.2.0/syntax/literals_rdoc.html#label-Here+Document+Literals)
identified by HTML, will be parsed, and tags will be transformed into Ruby code.

Then it creates a class that inherits from `Component::Base`,
and calls methods on it asynchronously.

## Getting started

Make sure you have Ruby 3.2 and bundler, then run:

    bundle install

To start the thing, type:

    ruby config.ru

## Limitations

### No resuming

If the connection drops, all state is lost.

### Reordering is not implemented

I'm not really sure how to solve it,
but I think a clean solution lies behind the corner.

If each node calculates some sort of index hash based on their neighbors,
it might be possible for them to detect that they have moved...
