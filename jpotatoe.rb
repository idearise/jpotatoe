#!/usr/bin/env jruby
# ^ Place the full path to the jruby binary if needed

#   Copyright 2008 Idearise LLC
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

require 'rubygems'
require 'logger'
require 'json/pure' # sudo jruby -S gem install json_pure
require 'rest_client' # sudo jruby -S gem install rest-client

class Jpotatoe

  class Replication
    def initialize(url, source, target)
      default_url = "http://127.0.0.1:5984/"
      @rez = RestClient::Resource.new(url || "#{default_url}_replicate")
      @source = (source || default_url)
      @target = (target || default_url)
    end
    
    def create(db)
      json_msg = {:source => "#{@source}#{db}", 
                  :target => "#{@target}#{db}"}.to_json
      response = @rez.post json_msg, 
                           :content_type => 'application/json'
      results = JSON.parse response
    end
  end

  def initialize(config={})
    @logger = Logger.new('/usr/local/var/log/couchdb/jpotatoe.log', 3, 1024000)
    @logger.level = Logger::INFO
    @logger.info "Initializing..."
    
    @replication = Replication.new( config[:replicate_url], 
                                    config[:source],
                                    config[:target] )
    @databases = (config[:databases] || {})
    @batch_size = (config[:batch_size] || 100)
    @x_seconds = (config[:x_seconds] || 600)
    @mutex = Mutex.new
  end

  def watch
    @timed_thr = time_watch # timed thread

    @logger.info "Waiting for messages..."
    loop do
      unless (json_out = gets).nil?
        @logger.debug json_out
        read json_out
      else
        @logger.info "CouchDB has gone away..."
        @timed_thr.terminate
        break
      end
    end
  rescue Exception => e
    @logger.error "Error message: #{e.message}"
    @logger.error "Stack trace: #{e.backtrace.inspect}"
  end

protected

  def read(json)
    msg = JSON.parse json
    if is_db_update? msg
      @logger.info "'#{msg['db']}' database updated."
      @mutex.synchronize { @databases[msg["db"]] += 1 }
      batch_watch msg["db"]
    end 
  end

  def is_db_update?(message)
    ( message["type"] == "updated" and @databases.has_key?(message["db"]) )
  end
  
  def time_watch
    return Thread.new do
      loop do
        @logger.info "Timed replication waiting #{@x_seconds} seconds..."
        sleep @x_seconds
        time_check
      end
    end
  end

  def time_check
    @mutex.synchronize do
      @logger.info "Timed check of db updates..."
      @databases
    end.each do |db,count|
      if count > 0
        @logger.info "Timed check found '#{db}' has #{count} updates. " +
                     "Starting timed replication..."
        replicate db
      end
    end
  end

  def batch_watch(db)
    if batch_is_ready?(db)
      @logger.info "Starting batch replication for #{db}..."
      replicate db
    end
  end

  def batch_is_ready?(db)
    return @mutex.synchronize do
      @logger.info "#{db} has #{@databases[db]} updates. "
      (@databases[db] >= @batch_size)
    end
  end

  def replicate(db)
    Thread.new do
      check_results_of(@replication.create(db), db)
    end
  end
  
  def check_results_of(response, db)
    if response["ok"]
      @mutex.synchronize { @databases[db] = 0 }
      @logger.info "#{db} replication succeeded. " + 
                  "session_id: #{response['session_id']} " + 
                  "source_last_seq: #{response['source_last_seq']}"
    else
      # Currently, CouchDB 0.8.1 doesn't work this way.
      # It returns an HTTP 500 error instead of false.
      @logger.info "#{response['db']} replication error: #{response}"
    end
  end

end

# Example
replicate_url = "http://192.168.0.4:5984/_replicate"
source = "http://192.168.0.4:5984/" # with trailing slash
target = "http://192.168.0.2:5984/" # with trailing slash
databases = { "mytestdb" => 0 } # { "name_in_quotes" => default_update_count }
config = { :replicate_url => replicate_url,
           :source => source,
           :target => target,
           :databases => databases,
           :batch_size => 50, 
           :x_seconds => 1800 }
# Batch size is the number of database updates to wait for before initializing
# the replication process.  A database updates may not necessarily mean a 
# document has been updated.  The script will also start the replication process
# every X seconds to make sure that the target database is updated every so 
# often.

Jpotatoe.new(config).watch
