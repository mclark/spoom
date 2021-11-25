# typed: true
# frozen_string_literal: true

require_relative '../coverage'
require_relative '../timeline'

module Spoom
  module Cli
    class Coverage < Thor
      include Helper

      DATA_DIR = "spoom_data"

      default_task :snapshot

      desc "snapshot", "Run srb tc and display metrics"
      option :save, type: :string, lazy_default: DATA_DIR, desc: "Save snapshot data as json"
      option :rbi, type: :boolean, default: true, desc: "Include RBI files in metrics"
      option :sorbet, type: :string, desc: "Path to custom Sorbet bin"
      def snapshot
        in_sorbet_project!
        path = exec_path
        sorbet = options[:sorbet]

        snapshot = Spoom::Coverage.snapshot(path: path, rbi: options[:rbi], sorbet_bin: sorbet)
        snapshot.print

        save_dir = options[:save]
        return unless save_dir
        FileUtils.mkdir_p(save_dir)
        file = "#{save_dir}/#{snapshot.commit_sha || snapshot.timestamp}.json"
        File.write(file, snapshot.to_json)
        say("\nSnapshot data saved under `#{file}`")
      end

      desc "timeline", "Replay a project and collect metrics"
      option :from, type: :string, desc: "From commit date"
      option :to, type: :string, default: Time.now.strftime("%F"), desc: "To commit date"
      option :save, type: :string, lazy_default: DATA_DIR, desc: "Save snapshot data as json"
      option :bundle_install, type: :boolean, desc: "Execute `bundle install` before collecting metrics"
      option :sorbet, type: :string, desc: "Path to custom Sorbet bin"
      def timeline
        in_sorbet_project!
        path = exec_path
        sorbet = options[:sorbet]

        ref_before = Spoom::Git.current_branch
        ref_before = Spoom::Git.last_commit(path: path) unless ref_before
        unless ref_before
          say_error("Not in a git repository")
          say_error("\nSpoom needs to checkout into your previous commits to build the timeline.", status: nil)
          exit(1)
        end

        unless Spoom::Git.workdir_clean?(path: path)
          say_error("Uncommited changes")
          say_error(<<~ERR, status: nil)

            Spoom needs to checkout into your previous commits to build the timeline."

            Please `git commit` or `git stash` your changes then try again
          ERR
          exit(1)
        end

        save_dir = options[:save]
        FileUtils.mkdir_p(save_dir) if save_dir

        from = parse_time(options[:from], "--from")
        to = parse_time(options[:to], "--to")

        unless from
          intro_sha = Spoom::Git.sorbet_intro_commit(path: path)
          intro_sha = T.must(intro_sha) # we know it's in there since in_sorbet_project!
          from = Spoom::Git.commit_time(intro_sha, path: path)
        end

        timeline = Spoom::Timeline.new(from, to, path: path)
        ticks = timeline.ticks

        if ticks.empty?
          say_error("No commits to replay, try different `--from` and `--to` options")
          exit(1)
        end

        ticks.each_with_index do |sha, i|
          date = Spoom::Git.commit_time(sha, path: path)
          say("Analyzing commit `#{sha}` - #{date&.strftime('%F')} (#{i + 1} / #{ticks.size})")

          Spoom::Git.checkout(sha, path: path)

          snapshot = T.let(nil, T.nilable(Spoom::Coverage::Snapshot))
          if options[:bundle_install]
            Bundler.with_unbundled_env do
              next unless bundle_install(path, sha)
              snapshot = Spoom::Coverage.snapshot(path: path, sorbet_bin: sorbet)
            end
          else
            snapshot = Spoom::Coverage.snapshot(path: path, sorbet_bin: sorbet)
          end
          next unless snapshot

          snapshot.print(indent_level: 2)
          say("\n")

          next unless save_dir
          file = "#{save_dir}/#{sha}.json"
          File.write(file, snapshot.to_json)
          say("  Snapshot data saved under `#{file}`\n\n")
        end
        Spoom::Git.checkout(ref_before, path: path)
      end

      desc "report", "Produce a typing coverage report"
      option :data, type: :string, default: DATA_DIR, desc: "Snapshots JSON data"
      option :file, type: :string, default: "spoom_report.html", aliases: :f,
        desc: "Save report to file"
      option :color_ignore, type: :string, default: Spoom::Coverage::D3::COLOR_IGNORE,
        desc: "Color used for typed: ignore"
      option :color_false, type: :string, default: Spoom::Coverage::D3::COLOR_FALSE,
        desc: "Color used for typed: false"
      option :color_true, type: :string, default: Spoom::Coverage::D3::COLOR_TRUE,
        desc: "Color used for typed: true"
      option :color_strict, type: :string, default: Spoom::Coverage::D3::COLOR_STRICT,
        desc: "Color used for typed: strict"
      option :color_strong, type: :string, default: Spoom::Coverage::D3::COLOR_STRONG,
        desc: "Color used for typed: strong"
      def report
        in_sorbet_project!

        data_dir = options[:data]
        files = Dir.glob("#{data_dir}/*.json")
        if files.empty?
          message_no_data(data_dir)
          exit(1)
        end

        snapshots = files.sort.map do |file|
          json = File.read(file)
          Spoom::Coverage::Snapshot.from_json(json)
        end.filter(&:commit_timestamp).sort_by!(&:commit_timestamp)

        palette = Spoom::Coverage::D3::ColorPalette.new(
          ignore: options[:color_ignore],
          false: options[:color_false],
          true: options[:color_true],
          strict: options[:color_strict],
          strong: options[:color_strong]
        )

        report = Spoom::Coverage.report(snapshots, palette: palette, path: exec_path)
        file = options[:file]
        File.write(file, report.html)
        say("Report generated under `#{file}`")
        say("\nUse `spoom coverage open` to open it.")
      end

      desc "open", "Open the typing coverage report"
      def open(file = "spoom_report.html")
        unless File.exist?(file)
          say_error("No report file to open `#{file}`")
          say_error(<<~ERR, status: nil)

            If you already generated a report under another name use #{blue('spoom coverage open PATH')}.

            To generate a report run #{blue('spoom coverage report')}.
          ERR
          exit(1)
        end

        exec("open #{file}")
      end

      desc "sig-candidates", "List methods that should get typed first"
      def sig_candidates(*files)
        in_sorbet_project!

        path = exec_path
        config = sorbet_config
        files = Spoom::Sorbet.srb_files(config, path: path) if files.empty?

        if files.empty?
          say_error("No file matching `#{sorbet_config_file}`")
          exit(1)
        end

        collector = SigCandidates::Collector.new
        files.each do |file|
          next if File.extname(file) == ".rbi"
          collector.collect_file(file)
        end
        # collector.status

        lsp_root = File.expand_path(path)
        lsp = Spoom::LSP::Client.new(
          Spoom::Sorbet::BIN_PATH,
          "--lsp",
          "--enable-all-experimental-lsp-features",
          "--disable-watchman",
          path: lsp_root
        )

        lsp.open(lsp_root)

        collector.sends.each do |key, send|
          next if SigCandidates::Collector::EXCLUDED_SENDS.include?(key)
          send.nodes.each do |file, node|
            selector = node.location.selector
            line = selector.line
            column = selector.column

            recv = node.children.first
            recv_type = "<self>"
            if recv
              recv_loc = recv.location.expression
              recv_line = recv_loc.line
              recv_column = recv_loc.column
              recv_hover = lsp.hover(to_uri(file), recv_line - 1, recv_column + 1)&.contents
              recv_type = recv_hover.lines.first.strip if recv_hover
            end

            print("Calling `#{recv_type}##{key}` at #{file}:#{line}:#{column}: ")
            hover = lsp.hover(to_uri(file), line - 1, column + 1)&.contents
            if hover && hover.match?("sig")
              puts hover.lines.first
            else
              puts "no sig"
            end
          end
        end

        lsp.close
      end

      no_commands do
        def to_uri(path, root_path: exec_path)
          "file://" + File.join(File.expand_path(root_path), path)
        end

        def parse_time(string, option)
          return nil unless string
          Time.parse(string)
        rescue ArgumentError
          say_error("Invalid date `#{string}` for option `#{option}` (expected format `YYYY-MM-DD`)")
          exit(1)
        end

        def bundle_install(path, sha)
          opts = {}
          opts[:chdir] = path
          out, status = Open3.capture2e("bundle install", opts)
          unless status.success?
            say_error("Can't run `bundle install` for commit `#{sha}`. Skipping snapshot")
            say_error(out, status: nil)
            return false
          end
          true
        end

        def message_no_data(file)
          say_error("No snapshot files found in `#{file}`")
          say_error(<<~ERR, status: nil)

            If you already generated snapshot files under another directory use #{blue('spoom coverage report PATH')}.

            To generate snapshot files run #{blue('spoom coverage timeline --save-dir spoom_data')}.
          ERR
        end
      end
    end
  end
end
