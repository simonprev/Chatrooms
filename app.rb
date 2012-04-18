#Encoding.default_external = Encoding::UTF_8
#Encoding.default_internal = Encoding::UTF_8

require 'bundler'
Bundler.require :default
require 'digest'
require 'stringio'

class Message# {{{
  attr_accessor :content
  attr_accessor :from
  attr_accessor :to
  attr_accessor :created_at
  attr_accessor :messages
  attr_accessor :channel

  def initialize args
    self.content = args[:content]
    self.from = args[:from]
    self.channel = args[:channel]
    self.to = args[:to]
    self.created_at = Time.now
  end

  def to_h
    output = {
      :content => self.content,
      :channel => self.channel,
      :from => self.from,
      :created_at => self.created_at,
    }
    output.merge!(:to => self.to) if self.to
    output.to_json
  end

end# }}}

class EventedRedis < EM::Connection# {{{
  def self.connect
    host = (ENV['REDIS_HOST'] || 'localhost')
    port = (ENV['REDIS_PORT'] || 6379).to_i
    EM.connect host, port, self
  end

  def post_init
    @blocks = {}
  end

  def subscribe(*channels, &blk)
    channels.each { |c| @blocks[c.to_s] = blk }
    call_command('subscribe', *channels)
  end

  def unsubscribe(channel = "")
    call_command('unsubscribe', channel)
  end

  def receive_data(data)
    buffer = StringIO.new(data)
    begin
      parts = read_response(buffer)
      if parts.is_a?(Array)
        ret = @blocks[parts[1]].call(parts)
        close_connection if ret === false
      end
    end while !buffer.eof?
  end

  private
  def read_response(buffer)
    type = buffer.read(1)
    case type
    when ':'
      buffer.gets.to_i
    when '*'
      size = buffer.gets.to_i
      parts = size.times.map { read_object(buffer) }
    else
      raise "unsupported response type"
    end
  end

  def read_object(data)
    type = data.read(1)
    case type
    when ':' # integer
      data.gets.to_i
    when '$'
      size = data.gets
      str = data.read(size.to_i)
      data.read(2) # crlf
      str
    else
      raise "read for object of type #{type} not implemented"
    end
  end

  # only support multi-bulk
  def call_command(*args)
    command = "*#{args.size}\r\n"
    args.each { |a|
      command << "$#{a.to_s.size}\r\n"
      command << a.to_s
      command << "\r\n"
    }
    send_data command
  end

end# }}}

Cramp::Websocket.backend = :thin

class ServerController < Cramp::Action

  self.transport = :websocket

  OFFLINE_COMMANDS = [# {{{
    "login",
    "create_user"
  ]# }}}

  attr_accessor :user
  attr_accessor :logged
  attr_accessor :params
  attr_accessor :action

  on_start :create_redis
  on_data :receive_data
  on_finish :logout, :destroy_redis

  def create_redis# {{{
    @sub = EventedRedis.connect
    @redis = Redis.new
  end# }}}

  def destroy_redis# {{{
    @sub.close_connection_after_writing
    @redis.quit
    @redis = nil
  end# }}}


    # Available commands# {{{
    def list_channels# {{{
      return success :channels => @redis.smembers("channels")
    end# }}}

    def list_online_users# {{{
      users = []
      key = @params[:channel] ? "channel:#{@params[:channel]}:users" : "online_users"
      @redis.smembers(key).each do |user|
        users << @redis.mapped_hmget(user, "fullname", "status")
      end
      return success :users => users
    end# }}}

    def list_users# {{{
      users = []
      @redis.smembers("users").each do |user|
        users << @redis.mapped_hmget(user, "fullname", "status")
      end
      return success :users => users
    end# }}}

    def create_user# {{{
      return bail 500, "missing_parameters" if missing_params([:email, :fullname, :username, :password])
      unless self.login?
        key = "user:#{@params[:email]}"
        unless @redis.exists(key)
          salt = Digest::SHA256.hexdigest(@params[:email])
          password = Digest::SHA256.hexdigest(salt + @params[:password])
          self.user = { :fullname => @params[:fullname], :email => @params[:email], :password => password, :username => @params[:username] }
          @redis.mapped_hmset key, user
          @redis.sadd 'users', key
          login_user
          return success :user => user
        else
          return bail 403, :already_exists
        end
      else
        return bail 403, :already_logged
      end
    end#}}}

    def update_user# {{{
      @redis.pipelined do
        @redis.mapped_hmset user_key, @params
        self.user = @redis.mapped_hmget user_key, 'fullname', 'password', 'username', 'email'
      end
      return success :user => self.user
    end# }}}

    def logout# {{{
      if self.user
        user_subscriptions_keys = user_key+":subscriptions"
        @redis.pipelined do
          if @redis.exists(user_subscriptions_keys)
            @redis.smembers(user_subscriptions_keys).each do |channel|
              @redis.srem "channel:#{channel}:users", user_key
              count = @redis.scard "channel:#{channel}:users"
              @redis.srem 'channels', channel if count <= 0
            end

            @redis.del user_subscriptions_keys
          end
          @redis.mapped_hmset user_key, {"status" => "offline"}
          @redis.srem 'online_users', user_key
        end
        self.user = nil
        self.logged = false
      end
      return success 'logout'
    end# }}}

    def login# {{{
      return bail 403, "already_logged" if self.user
      return bail 500, "missing_parameters" if missing_params([:email, :password])
      user = @redis.mapped_hmget "user:#{@params[:email]}", 'fullname', 'password', 'username', 'email', 'notif'
      salt = Digest::SHA256.hexdigest(@params[:email])
      entered_password = Digest::SHA256.hexdigest(salt + @params[:password])

      if user["password"] == entered_password
        self.user = user
        login_user
        return success :user => self.user
      else
        return bail 403, "invalid_credentials"
      end
    end# }}}

    def subscribe #{{{
      return bail 500, "missing_parameters" if missing_params([:channel])
      user_subscriptions_keys = user_key+":subscriptions"
      return bail 403, "already_subscribed" if @redis.sismember(user_subscriptions_keys,@params[:channel])

      @redis.pipelined do
        @redis.sadd user_subscriptions_keys, @params[:channel]
        @redis.sadd 'channels', @params[:channel]
        @redis.sadd "channel:#{@params[:channel]}:users", user_key
      end

      @sub.subscribe(@params[:channel]) do |type,channel,message|
        @action = "received"
        success(:message => message) unless ["subscribe","unsubscribe"].include? type
      end
      return success :subscriptions => @redis.smembers(user_subscriptions_keys)
    end# }}}

    def publish# {{{
      return bail 500, "missing_parameters" if missing_params([:channel, :msg])
      message = Message.new(:channel => @params[:channel], :content => @params[:msg], :from => self.user['fullname'])
      message.to = deliver(message).to_s
      return success :message => message.to_h
    end# }}}

    def offline_publish# {{{
      return bail 500, "missing_parameters" if missing_params([:user, :msg])
      message = Message.new(:channel => "user:"+@params[:user], :content => @params[:msg], :from => self.user['fullname'])
      key = "user:#{@params[:user]}"
      pending_set_key = key+":pending"
      @redis.hincrby key,'notif', 1
      @redis.sadd pending_set_key, message.to_h
      return success :message => message.to_h
    end# }}}

    def unsubscribe# {{{
      return bail 500, "missing_parameters" if missing_params([:channel])

      user_subscriptions_keys = user_key+":subscriptions"
      @redis.srem "channel:#{@params[:channel]}:users", user_key
      count = @redis.scard "channel:#{@params[:channel]}:users"
      @redis.srem user_subscriptions_keys, @params[:channel]
      @redis.srem 'channels', @params[:channel] if count <= 0

      @sub.unsubscribe(@params[:channel])
      return success "unsubscribed_from_#{@params[:channel]}"
    end# }}}

    def private_message# {{{
      return bail 500, "missing_parameters" if missing_params([:user])
      key = "user:#{@params[:user]}"
      return bail 404, "unknown_user" unless @redis.sismember('users',key)
      @params[:channel] = key
      @redis.sismember('online_users',key) ? publish : offline_publish
    end# }}}

    def pending_messages# {{{
      messages = []
      pending_key = user_key + ":pending"
      messages_key = user_key + ":private_messages"
      @redis.smembers(pending_key).each do |message|
        messages << message
        @redis.smove pending_key, messages_key, message
        @redis.hincrby user_key, 'notif', -1
      end
      return success :messages => messages
    end# }}}

    def list_private_messages# {{{
      messages = []
      messages_key = user_key + ":private_messages"
      @redis.smembers(messages_key).each { |message| messages << message }
      return success :messages => messages
    end# }}}
    # }}}


  def receive_data data# {{{
    input = parse(data)
    if input.is_a? Hash
      if self.login?
        if input[:cmd] and self.respond_to?(input[:cmd])
          self.send(input[:cmd]) #rescue(return bail 500, 'something_awful_happened')
        else
          return bail 500, 'unknown_command'
        end
      else
        if input[:cmd] and OFFLINE_COMMANDS.include?(input[:cmd])
          self.send(input[:cmd]) #rescue(return bail 500, 'something_awful_happened')
        else
          return bail 403, 'missing_credentials'
        end
      end
    end
  end# }}}

  def parse(data)# {{{
    output = {}
    data.rstrip!

    begin
      parsed_data = JSON.parse(data)
    rescue
      return bail 500, "invalid_json"
    end

    output[:cmd]    = parsed_data["cmd"]
    output[:msg]    = parsed_data["msg"]
    output[:params] = parsed_data["params"]
    @params = {}
    @action = output[:cmd]

    if parsed_data["params"]
      begin
        parsed_data["params"].each do |key,value|
          @params[(key.to_sym rescue key)] = value
          @params.delete(key)
        end
      rescue
        return bail 500, "invalid_params"
      end
    end

    return output
  end# }}}

  def success object# {{{
    output = {:code => 200, :data => object}
    write output
  end# }}}

  def bail code, message# {{{
    output = {:code => code, :message => message}
    write output
  end# }}}

  def deliver msg# {{{
    @redis.publish(msg.channel, msg.to_h)
  end# }}}

  def write(data)# {{{
    render(data.merge!(:action => @action).to_json)
  end# }}}

  def missing_params(required)# {{{
    missing = @params.keys.each {|p| break unless required.include? p }
    out = missing ? missing.size != required.size : false
    return out
  end# }}}

  def login?# {{{
    self.logged
  end# }}}

  private
  def login_user
    self.logged = true
    user_subscriptions_keys = user_key+":subscriptions"
    @redis.pipelined do
      @redis.sadd 'online_users', "user:#{@params[:email]}"
      @redis.mapped_hmset "user:#{@params[:email]}", {"status" => "available"}
      @redis.del user_subscriptions_keys
    end
    @sub.subscribe(user_key) do |type,channel,message|
      success(message.to_json) unless ["subscribe","unsubscribe"].include? type
    end
  end

  def user_key
    "user:#{self.user["email"]}"
  end

end

EventMachine.run {
  Rack::Handler::Thin.run ServerController, :Port => 8081
}
