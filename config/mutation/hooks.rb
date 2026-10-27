# frozen_string_literal: true

hooks.register(:setup_integration_post) do
  experiment = MutationExperiment.load(ENV.fetch('MUTATION_EXPERIMENT'), ENV.fetch('MUTATION_SUITE'))
  expected = experiment.fetch('specs').map { |path| File.expand_path(path) }.uniq
  examples = RSpec.world.example_groups.flat_map(&:descendants).flat_map(&:examples)
  abort 'No examples loaded' if examples.empty?
  actual = examples.map { |example| File.expand_path(example.metadata.fetch(:file_path)) }.uniq
  unless actual.sort == expected.sort
    abort 'Loaded spec files differ from configured suite; refusing an incomplete or mixed run'
  end
  unless examples.all? { |example| example.metadata[:mutant_expression] == experiment.fetch('target') }
    abort 'Some examples lack the common target mutation mapping'
  end
  puts "MUTATION EXPERIMENT #{experiment.fetch('name')}/#{experiment.fetch('suite')}: #{examples.length} examples mapped to #{experiment.fetch('target')}"

  # Forked processes must open their own MySQL connections, not reuse parent sockets.
  ActiveRecord::Base.connection_handler.clear_all_connections!
end

[:test_worker_process_start, :mutation_worker_process_start].each do |event|
  hooks.register(event) do |index:|
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end
end
