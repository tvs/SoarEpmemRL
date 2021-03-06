#!/usr/bin/env ruby

require 'optparse'
require 'gruff'
require 'yaml'

class Food
  attr_reader :score, :health
  def initialize(score, health)
    @score = score
    @health = health
  end
end

class QValues
  attr_reader :Q
  def initialize(alpha = 0.5, gamma = 0.5)
    @alpha = alpha
    @gamma = gamma
    @Q = Hash.new(0)
  end

  def update(action, reward)
    max_action, max_value = @Q.max_by { |k,v| v }
    @Q[action] = @Q[action]*(1-@alpha) + @alpha*(reward + @gamma*max_value)
  end

  def update_dead(action, reward)
    @Q[action] = @Q[action]*(1-@alpha) + @alpha*(reward)
  end

  def [](key)
    @Q[key]
  end

  def []=(key,value)
    @Q[key] = value
  end

  def max_by(&block)
    @Q.max_by(&block)
  end
end

class Agent

  WELLS = {
    :unhealthy => Food.new(10, -5),
    :healthy   => Food.new(6, 0)
  }

  attr_accessor :qvalues
  attr_reader :run_number, :days_lived, :history, :health, :history
  def initialize(options, hush=false, thinker=false, &block)
    @options = options # maintain for "thinking"
    @thinker = thinker

    @retain_qvalues = options[:retain]
    @epsilon = options[:epsilon]
    @alpha = options[:alpha]
    @gamma = options[:gamma]
    @exploration = options[:exploration]
    @checkup_frequency = options[:checkup]
    @thinking_frequency = options[:thinking_frequency]
    @thinking_runs = options[:thinking_runs]
    @thinking_steps = options[:thinking_steps]
    @health_max = options[:health]

    @history_file = options[:history]
    @graph_file = options[:graph]

    @hush = hush

    @run_number = 0

    # Optional code block can be specified at creation for different food-picking behavior
    @pick_food_block = block

    graph_setup
  end

  def graph_setup
    unless @thinker
      @graph_q = Gruff::Line.new
      @graph_q.theme_rails_keynote
      @graph_q.hide_dots = true
      colors = @graph_q.colors
      colors << '#daaea9'
      colors << '#daaeda'
      @graph_q.colors = colors
      @graph_q.title = "Q-Values"
    end
  end

  def reset()
    @run_number += 1
    @health = @known_health = @health_max
    @doctor_count = 0
    @days_lived = 0
    @contemplation_count = 0
    @history_last = nil
    @history = []

    if !@thinker and (!@retain_qvalues or @run_number == 1)
      @qvalues = QValues.new(@alpha, @gamma)
      WELLS.keys.each do |key|
        @qvalues[key] = 0
      end
    end

    @graph_data = Hash.new { |h, k| h[k] = [] }
  end

  def run(steps=-1)
    reset

    until @health <= 0
      live_day
      doctors_checkup if checkup_time
      break if !steps.nil? and @days_lived == steps
    end

    assess_lifespan
    add_to_graph

    @history_file.puts @history.inspect if @history_file
  end

  def checkup_time
    @checkup_frequency > 0 and @days_lived > 0 and @days_lived % @checkup_frequency == 0
  end

  def thinking_time
    @thinking_frequency > 0 and @doctor_count > 0 and @doctor_count % @thinking_frequency == 0
  end

  def live_day()
    well = pick_food &@pick_food_block
    eat(well)
    @days_lived += 1
  end

  # Yields q-values to optional block
  def pick_food()
    if block_given?
      # Can be used to simulate experiences?
      yield @qvalues
    else
      # Default food behavior
      r = rand()

      # NOTE: N% of the time pick randomly (after exploration)
      if r < @epsilon or @days_lived < @exploration
        WELLS.keys.sample
      else
        @qvalues.max_by { |k, v| v }[0]
      end
    end
  end

  def eat(well)
    update_history(well)
    food = WELLS[well]
    update_score(well, food)
    update_health(well, food)
  end

  def update_history(well)
    @history_last = well
    @history << well unless @history_file.nil?
  end

  def update_score(well, food)
    @qvalues.update(well, food.score) unless checkup_time
    update_graph_data
  end

  def update_health(well, food)
    @health += food.health
  end

  def doctors_checkup
    @doctor_count += 1
    difference = @health - @known_health
    @known_health = @health

    food = WELLS[@history_last]
    @qvalues.update(@history_last, food.score + difference)
    print "    " if @thinker and !@hush
    puts "Run ##{@run_number} Difference: #{difference} (#{food.score + difference}) - #{@history_last} (#{@qvalues[@history_last]}): #{@health}" unless @hush

    contemplate_life if thinking_time

    #update_graph_data
  end

  def contemplate_life
    unless @thinker
      puts "Contemplate life: ##{@contemplation_count}" unless @hush
      contemplate_options = @options.merge({:history => nil, :retain => true})

      # Set to be a thinker (avoid recursive thinking)
      agent = Agent.new(contemplate_options, @hush, true) do
        @history_last
      end

      agent.qvalues = @qvalues.clone
      @thinking_runs.times do
        agent.run(@thinking_steps)
      end
      @qvalues = agent.qvalues
      puts "Ceased contemplation" unless @hush
      @contemplation_count += 1
    end
  end

  def assess_lifespan
    unless @thinker
      @qvalues.update_dead(@history_last, -100)
      #update_graph_data
    end
  end

  def update_graph_data
    unless @thinker
      @graph_data[:unhealthy] << @qvalues[:unhealthy]
      @graph_data[:healthy] << @qvalues[:healthy]
    end
  end

  def add_to_graph
    unless @thinker
      @graph_max ||= @days_lived
      @graph_max = [@graph_max, @days_lived].max
      @graph_q.data("Unhealthy (#{@run_number})", @graph_data[:unhealthy])
      @graph_q.data("Healthy (#{@run_number})", @graph_data[:healthy])
    end
  end

  def save_graph
    think_label = @checkup_frequency * @thinking_frequency
    @graph_q.labels = { @graph_max-1 => "#{@graph_max-1}",
                        @exploration => "E:#{@exploration}",
                        @checkup_frequency => "C:#{@checkup_frequency}",
                        think_label => "T:#{think_label}" }
    @graph_q.write(@graph_file)
  end

  def to_yaml
    @options.to_yaml
  end
end

OPTIONS = {
  ## Batch config file
  :config => nil,

  ## Agent settings
  :checkup => 10,
  :thinking_frequency => 10,
  :thinking_runs => 1,
  :thinking_steps => 200,
  :exploration => 50,
  :epsilon => 0.1,
  :alpha => 0.2,
  :gamma => 0.8,
  :health => 100,
  :retain => false,
  :history => false,
  :graph => "q-values.png",

  ## Script settings
  :runs => 1,
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on("--config [FILE]", "Configuration file for batched experiments") do |f|
    OPTIONS[:config] = f
  end

  opts.on("-c", "--checkup [NUM]", Integer, "Checkup frequency",
          "   Default: #{OPTIONS[:checkup]}") do |i|
    OPTIONS[:checkup] = i
  end

  opts.on("-t", "--thinking-frequency [NUM]", Integer, "Thinking frequency (in number of checkups)",
          "   Default: #{OPTIONS[:thinking_frequency]}") do |i|
    OPTIONS[:thinking_frequency] = i
  end

  opts.on("-x", "--thinking-runs [NUM]", Integer, "Number of runs to think over)",
          "   Default: #{OPTIONS[:thinking_runs]}") do |i|
    OPTIONS[:thinking_runs] = i
  end

  opts.on("-z", "--thinking-steps [NUM]", Integer, "Number of steps to limit thinking to (-1 for inf)",
          "   Default: #{OPTIONS[:thinking_steps]}") do |i|
    OPTIONS[:thinking_steps] = i
  end

  opts.on("-e", "--exploration [NUM]", Integer, "Number of exploration stage choices",
          "   Default: #{OPTIONS[:exploration]}") do |i|
    OPTIONS[:exploration] = i
  end

  opts.on("-p", "--epsilon [FLOAT]", Float, "Greedy epsilon value",
          "   Default: #{OPTIONS[:epsilon]}") do |f|
    OPTIONS[:epsilon] = f
  end

  opts.on("-a", "--alpha [FLOAT]", Float, "Alpha value for reinforcement learning",
          "   Default: #{OPTIONS[:alpha]}") do |f|
    OPTIONS[:alpha] = f
  end

  opts.on("-g", "--gamma [FLOAT]", Float, "Gamma value for reinforcement learning",
          "   Default: #{OPTIONS[:gamma]}") do |f|
    OPTIONS[:gamma] = f
  end

  opts.on("-h", "--health [NUM]", Integer, "Health value for the agent",
          "   Default: #{OPTIONS[:health]}") do |i|
    OPTIONS[:health] = i
  end

  opts.on("-y", "--history [FILE]", "History log file. If none supplied, will not log") do |f|
    OPTIONS[:history] = File.open(f, "w")
  end

  opts.on("-q", "--graph [FILE]", "Q-learning graph output file", "   Default: #{OPTIONS[:graph]}") do |f|
    OPTIONS[:graph] = f
  end

  opts.on("-r", "--runs [NUM]", Integer, "Number of runs for an agent",
          "   Default: #{OPTIONS[:runs]}") do |i|
    OPTIONS[:runs] = i
  end

  opts.on("--retain", "Retain Q-Values between runs", "   Default: #{OPTIONS[:retain]}") do
    OPTIONS[:retain] = true
  end

  opts.on("--save [FILE]", "Save options configuration to file. If none supplied, will not save") do |f|
    $save = File.open(f, "w")
  end

  opts.on("--[no-]hush", "Hush agent output") do |s|
    $hush = s
  end
end.parse!

# TODO Add ability to define the wells in CLI/config

unless OPTIONS[:config].nil?
  # Batch configuration
  experiments = YAML::load(File.open(OPTIONS[:config]))

  experiments.each_pair do |key, config|
    puts "Beginning Experiment: '#{key}'"
    full_config = OPTIONS.merge(config) # Merge with defaults to fill out partial
    agent = Agent.new(full_config, $hush)
    full_config[:runs].times do
      agent.run()
    end
    agent.save_graph
  end
else
  # Single shot run
  OPTIONS.delete(:config) # Pull this out so that the save looks a little cleaner

  agent = Agent.new(OPTIONS, $hush)
  OPTIONS[:runs].times do
    agent.run()
  end
  agent.save_graph

  unless $save.nil?
    $save.write agent.to_yaml
    $save.close
  end
end
