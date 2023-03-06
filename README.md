# rdom

🔥 live demo at [rdom.fly.dev](https://rdom.fly.dev/)

## Description

This is a very basic experiment.
For a more complete implementation,
see [Mayu Live](https://github.com/mayu-live/framework).

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
