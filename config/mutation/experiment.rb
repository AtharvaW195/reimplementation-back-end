# frozen_string_literal: true

require 'yaml'

# One source of configuration for the launcher, Rails bootstrap and worker hooks.
module MutationExperiment
  ROOT = File.expand_path('../..', __dir__)
  PATH = File.join(ROOT, 'config/mutation/experiments.yml')
  LABEL = /\A[a-zA-Z0-9_-]+\z/
  CONSTANT = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

  def self.load(name, suite)
    raise ArgumentError, 'Invalid experiment/suite label' unless LABEL.match?(name.to_s) && LABEL.match?(suite.to_s)

    experiments = YAML.safe_load_file(PATH).fetch('experiments')
    config = experiments.fetch(name) { raise ArgumentError, "Unknown experiment #{name.inspect}; choose: #{experiments.keys.join(', ')}" }
    target = config.fetch('target')
    raise ArgumentError, 'target must be a Ruby class/module name' unless target.is_a?(String) && CONSTANT.match?(target)

    suites = config.fetch('suites')
    raise ArgumentError, "Unknown suite #{suite.inspect}; choose: #{suites.keys.join(', ')}" unless suites.key?(suite)
    suites.each do |label, paths|
      raise ArgumentError, "Invalid suite label: #{label}" unless LABEL.match?(label.to_s)
      unless paths.is_a?(Array) && !paths.empty? && paths.all? { |path| path.is_a?(String) && path.end_with?('_spec.rb') }
        raise ArgumentError, "Suite #{label} must list explicit *_spec.rb files"
      end
      paths.each { |path| validate_file(path) }
    end
    validate_file(config.fetch('source'))
    subjects = config.fetch('subjects', [target])
    unless subjects.is_a?(Array) && !subjects.empty? && subjects.all? { |expression| target_expression?(expression, target) }
      raise ArgumentError, 'subjects must name the target constant or its methods'
    end
    if config.key?('pilot') && !target_expression?(config['pilot'], target)
      raise ArgumentError, 'pilot must name the target constant or one of its methods'
    end

    config.merge('name' => name, 'suite' => suite, 'specs' => suites.fetch(suite), 'subjects' => subjects)
  end

  def self.target_expression?(expression, target)
    expression.is_a?(String) &&
      (expression == target || expression.start_with?("#{target}#", "#{target}."))
  end

  def self.validate_file(path)
    raise ArgumentError, 'Expected a project-relative file path' unless path.is_a?(String)

    absolute = File.expand_path(path, ROOT)
    unless absolute.start_with?("#{ROOT}/") && File.file?(absolute)
      raise ArgumentError, "Missing file or path outside project: #{path}"
    end
  end
end
