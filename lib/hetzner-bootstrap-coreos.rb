require 'benchmark'
require 'logger'

require 'hetzner-api'
require 'hetzner/bootstrap/coreos/version'
require 'hetzner/bootstrap/coreos/target'
require 'hetzner/bootstrap/coreos/cloud_config'

module Hetzner
  class Bootstrap
    class CoreOS
      attr_accessor :targets
      attr_accessor :api
      attr_accessor :actions
      attr_accessor :logger
      attr_accessor :discovery_url
      attr_accessor :docker_swarm

      def initialize(options = {})
        @targets = []
        @actions = %w(
            remove_from_local_known_hosts
            enable_rescue_mode
            reset
            wait_for_ssh_down
            wait_for_ssh_up
            update_local_known_hosts
            installimage
            reboot
            wait_for_ssh_down
            wait_for_ssh_up
            update_local_known_hosts
            remove_from_local_known_hosts
            verify_installation
            configure_route
            docker_swarm
            post_install
            post_install_remote
        )
        @api = options[:api]
        @discovery_url = get_discovery_url
        @docker_swarm = options[:docker_swarm] ? :docker_swarm : false
      end

      def add_target(param)
        if param.is_a? Hetzner::Bootstrap::CoreOS::Target
          @targets << param
        else
          @targets << (Hetzner::Bootstrap::CoreOS::Target.new param)
        end
      end

      def get_discovery_url
        Net::HTTP.get(URI('https://discovery.etcd.io/new'))
      end

      def <<(param)
        add_target param
      end

      def bootstrap!(options = {})
        logger = Logger.new(STDOUT)
        logger.info "#{sprintf "%-20s", "START"}"

        manager = false
        workers = []
        join_token = ''
        join_address = ''

        if @docker_swarm
          logger.info "#{sprintf "%-20s", "Using Docker Swarm"}"

          @targets.each do |target|
            if target.manager? && !manager
              manager = target
            else
              workers.push(target)
            end
          end

          thread = start_thread(manager, options)
          thread.join()
          join_token = thread['join_token']
          join_address = manager.ip + ':2377'
        else
          workers = @targets
        end

        threads = workers.map do |target|
          if @docker_swarm
            target.use_join_token join_token
            target.use_join_address join_address
          end

          start_thread(target, options)
        end
        threads.each(&:join)

        logger.info "#{sprintf "%-20s", "DONE!"}"
        logger.info "#{sprintf "%-20s", "Discovery URL #{@discovery_url}"}"
      end

      def start_thread(target, options = {})
        Thread.new {
          target.use_api @api
          target.use_logger options[:logger] || Logger.new(STDOUT)
          target.use_discovery_url @discovery_url
          target.use_docker_swarm @docker_swarm
          bootstrap_one_target! target
        }
      end

      def bootstrap_one_target!(target)
        actions = (target.actions || @actions)
        actions.each_with_index do |action, index|
          loghack = "\b" * 24 # remove: "[bootstrap_one_target!] ".length
          target.logger.info "#{loghack}[#{action}] #{sprintf "%-20s", "START"}"
          d = Benchmark.realtime do
            target.send action
          end
          target.logger.info "#{loghack}[#{action}] FINISHED in #{sprintf "%.5f",d} seconds"
        end
      rescue => e
        target.logger.error "Something bad happened unexpectedly: #{e.class} => #{e.message}"
      end
    end
  end
end

