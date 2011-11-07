#!/usr/bin/env ruby
#
# vi:set et ai sw=2 sts=2 ts=2: */
# -
# Copyright (c) 2011 Jannis Pohlmann <jannis@xfce.org>
#
# This program is free software; you can redistribute it and/or 
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of 
# the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public 
# License along with this program; if not, write to the Free 
# Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
# Boston, MA 02110-1301, USA.

require 'rubygems'

require 'fileutils'
require 'json'
require 'optparse'
require 'ostruct'
require 'erb'
require 'pp'



# load repository information
DATA = JSON.load(open('repository.json'))



# define command line options
OPTIONS = OpenStruct.new
OPTIONS.clean = false
OPTIONS.run = true
OPTIONS.types = []
OPTIONS.graph_files = []
OPTIONS.algorithms = []
OPTIONS.verbose = false
OPTIONS.regenerate = false
OPTIONS.batch = false

# parse command line options
ARGV.options do |opts|
  opts.banner = 'Usage: %s [OPTIONS]' % $0

  opts.on('-b', '--batch', 'Batch processing (no interaction needed)') do |opt|
    OPTIONS.batch = true
  end

  opts.on('-c', '--cleanup', 'Clean up the build directory') do |opt|
    OPTIONS.clean = true
  end

  opts.on('-n', '--regenerate', 'Regenerate existing graphs') do |opt|
    OPTIONS.regenerate = true
  end

  opts.on('-v', '--verbose', 'Print the compile logs') do |opt|
    OPTIONS.verbose = true
  end

  opts.on('-t', '--type TYPE', 'Add graph type to generate drawings for') do |type|
    if DATA['graphs'].has_key?(type)
      OPTIONS.types << type
    else
      puts "graph type #{type} does not exist"
      exit 1
    end
  end

  opts.on('-f', '--file FILE', 'Add graph file to generate drawings for') do |file|
    if File.exists?(file)
      OPTIONS.graph_files << file
    else
      puts "graph file #{file} does not exist"
      exit 1
    end
  end

  opts.on('-a', '--algorithm ALGORITHM', 'Add algorithm to be used') do |algorithm|
    if DATA['algorithms'].has_key?(algorithm)
      OPTIONS.algorithms << algorithm
    else
      puts "algorithm #{algorithm} is not defined in repository.json"
      exit 1
    end
  end

  opts.on('-h', '--help', 'Display usage information') do
    puts
    puts opts
    puts
    exit
  end
end.parse!



if OPTIONS.clean 
  puts 'Cleaning up'
  puts
  begin
    puts '  Deleting the tmp/ directory'
    FileUtils.rm_rf('tmp') if File.directory?('tmp')
    raise if File.directory?('tmp')
  rescue
    puts '    Could not delete tmp/ directory'
    exit 1
  end
  begin
    puts '  Deleting the generated/ directory'
    FileUtils.rm_rf('generated') if File.directory?('generated')
    raise if File.directory?('generated')
  rescue
    puts '    Could not delete generated/ directory'
    exit 1
  end
  puts
  exit
end



OPTIONS.types = DATA['graphs'].select do |type, options| OPTIONS.types.include?(type) end



def generate(graph_type, graph, graph_name)
  puts "  Graph #{graph_type}/#{graph_name}"

  if not DATA['graphs'].has_key?(graph_type)
    puts "Graph type #{graph_type} is not defined in reposotory.json"
    exit 1
  end
  
  type_options = DATA['graphs'][graph_type]

  selected_algorithms = type_options['algorithms'].select do |algorithm, options|
    OPTIONS.algorithms.empty? or OPTIONS.algorithms.include?(algorithm)
  end

  if selected_algorithms.empty?
    puts "    No algorithms selected"
  else
    for algorithm, algorithm_options in selected_algorithms do
      puts "    Algorithm #{algorithm}"

      params = {'graph' => {}, 'algorithm' => {}}
      
      if type_options.has_key?('global parameters') 
        params['graph'].merge!(type_options['global parameters'])
      end

      if type_options.has_key?('graph parameters')
        if type_options['graph parameters'].has_key?(graph_name)
          if type_options['graph parameters'][graph_name].has_key?('graph')
            params['graph'].merge!(type_options['graph parameters'][graph_name]['graph'])
          end
        end
      end

      if algorithm_options.has_key?('parameters')
        if algorithm_options['parameters'].has_key?('graph')
          params['graph'].merge!(algorithm_options['parameters']['graph'])
        end

        if algorithm_options['parameters'].has_key?('algorithm')
          params['algorithm'].merge!(algorithm_options['parameters']['algorithm'])
        end
      end

      if algorithm_options['graph parameters'].has_key?(graph_name)
        if algorithm_options['graph parameters'][graph_name].has_key?('graph')
          params['graph'].merge!(algorithm_options['graph parameters'][graph_name]['graph'])
        end

        if algorithm_options['graph parameters'][graph_name].has_key?('algorithm')
          params['algorithm'].merge!(algorithm_options['graph parameters'][graph_name]['algorithm'])
        end
      end

      begin
        template_path = File.join('templates', DATA['algorithms'][algorithm]['template'])

        begin
          escaped_algorithm = algorithm.gsub(' ', '-')

          benchmark_dir = File.join('generated', 'benchmark-by-algorithm', algorithm, graph_type)
          benchmark_log_file = File.join(benchmark_dir, "#{graph_name}-#{escaped_algorithm}.log")
          benchmark_id = graph

          template_code = open(template_path) do |file| file.read end
          graph_code = open(graph) do |file| file.read end

          code = ERB.new(template_code).result(binding)

          tmp_dir = File.join('tmp', graph_type)
          
          unless File.directory?(tmp_dir)
            unless FileUtils.mkdir_p(tmp_dir)
              puts
              puts "Failed to create temporary directory #{tmp_dir}"
              exit 1
            end
          end

          tmp_file = File.join(tmp_dir, "#{graph_name}_#{escaped_algorithm}.tex")
          tmp_pdf_file = File.join(tmp_dir, "#{graph_name}_#{escaped_algorithm}.pdf")

          begin
            open(tmp_file, File::CREAT|File::RDWR|File::TRUNC) do |file|
              file.write(code)
            end
          rescue
            puts
            puts "Failed to write to temporary file #{tmp_file}"
            exit 1
          end

          build_dirs = [ 
            File.join('generated', 'by-algorithm', escaped_algorithm),
            File.join('generated', 'by-type', graph_type),
          ]

          incomplete_build_dirs = build_dirs.select do |dir| 
            not File.exists?(File.join(dir, File.basename(tmp_pdf_file)))
          end

          if incomplete_build_dirs.empty? and not OPTIONS.regenerate then
            puts "      Already generated"
          else
            unless File.directory?(benchmark_dir)
              unless FileUtils.mkdir_p(benchmark_dir)
                puts
                puts "Failed to create benchmark directory #{benchmark_dir}"
                exit 1
              end
            end
           
            begin
              open(benchmark_log_file, File::CREAT|File::TRUNC|File::RDWR) do |file|
               file.close
              end
            rescue
              puts
              puts "Failed to clear benchmark file #{benchmark_log_file}"
              exit 1
            end

            basename = File.basename(tmp_file)
            batch = OPTIONS.batch ? '--batchmode' : ''
            cmd = "cd #{tmp_dir} && context #{batch} --once \"#{basename}\""

            before = Time.now

            IO.popen(cmd) do |io|
              while io.gets
                puts $_ if OPTIONS.verbose
              end
            end

            after = Time.now
            elapsed = after - before

            puts "      Runtime: %.4f seconds" % elapsed.to_f

            for build_dir in build_dirs do
              unless File.directory?(build_dir)
                unless FileUtils.mkdir_p(build_dir)
                  puts
                  puts "Failed to create build dir #{build_dir}"
                  exit 1
                end
              end

              build_pdf_file = File.join(build_dir, "#{graph_name}_#{escaped_algorithm}.pdf")

              begin
                FileUtils.cp(tmp_pdf_file, build_pdf_file)
              rescue
                puts
                puts "Failed to copy #{tmp_pdf_file} to #{build_pdf_file}"
                exit 1
              end
            end
          end
        rescue IOError => e
          puts
          puts "Failed to load template #{template_path} for algorithm #{algorithm}"
          exit 1
        end
      rescue ArgumentError => e
        puts
        puts "No template defined for algorithm #{algorithm}"
        exit 1
      end
    end
  end
end



for graph_type, type_options in OPTIONS.types do
  puts "Drawing #{graph_type}"
  puts

  for graph in Dir.glob("src/#{graph_type}/*").sort do
    graph_name = File.basename(graph)
    
    generate(graph_type, graph, graph_name)

    puts
  end
end



unless OPTIONS.graph_files.empty?
  puts "Drawing selected graphs"
  puts

  for graph in OPTIONS.graph_files do
    basedir, graph_name = File.split(graph)
    basedir, graph_type = File.split(basedir)

    generate(graph_type, graph, graph_name)
    
    puts
  end
end
