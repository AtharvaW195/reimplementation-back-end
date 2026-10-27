# frozen_string_literal: true

require_relative 'experiment'

abort 'Use ruby bin/mutation to select an experiment and suite' unless ENV['MUTATION_EXPERIMENT'] && ENV['MUTATION_SUITE']
abort 'Mutation testing requires RAILS_ENV=test' unless ENV['RAILS_ENV'] == 'test'

experiment = MutationExperiment.load(ENV.fetch('MUTATION_EXPERIMENT'), ENV.fetch('MUTATION_SUITE'))
selected_paths = experiment.fetch('specs').map { |path| File.expand_path(path) }
target = experiment.fetch('target')

# Skip the existing SimpleCov start guard so mutation runs do not replace coverage evidence.
ENV['COVERAGE_STARTED'] = 'true'
require 'rspec/core'
RSpec.configure do |config|
  # Equalize selection despite the suites' different describe/context structures.
  config.define_derived_metadata do |metadata|
    if metadata[:file_path] && selected_paths.include?(File.expand_path(metadata[:file_path]))
      metadata[:mutant_expression] = target
    end
  end
end

require_relative '../environment'
database = ActiveRecord::Base.connection_db_config.database
abort "Refusing non-test database: #{database}" unless database.end_with?('_test')

# Check the database before rails_helper can maintain its schema or run cleanup hooks.
require_relative '../../spec/rails_helper'
Rails.application.eager_load!

# Resolve the requested constant explicitly; a typo must fail rather than yield no work.
target.constantize
