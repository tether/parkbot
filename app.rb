# encoding: utf-8
require "sinatra"
require "json"
require "httparty"
require "redis"
require "dotenv"
require "text"
require "sanitize"
require "chronic"

configure do
  Dotenv.load

  # Disable output buffering
  # See http://stackoverflow.com/questions/29998728/what-stdout-sync-true-means
  $stdout.sync = true

  # Set up redis
  case settings.environment
  when :development
    uri = URI.parse(ENV["LOCAL_REDIS_URL"])
  when :production
    uri = URI.parse(ENV["REDISCLOUD_URL"])
  end
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)

end

def json_response_for_slack(response)
  response = { text: response, link_names: 1 }
  response[:username] = ENV["BOT_USERNAME"] unless ENV["BOT_USERNAME"].nil?
  response[:icon_emoji] = ENV["BOT_ICON"] unless ENV["BOT_ICON"].nil?

  response.to_json
end

# Gets the given user's name(s) from redis.
# If it's not in redis, makes an API request to Slack to get it,
# and caches it in redis for a month.
# 
# Options:
# use_real_name => returns the users full name instead of just the first name
# 
def get_slack_name(user_id, options = {})
  options = { :use_real_name => false }.merge(options)
  key = "slack_user_names:2:#{user_id}"
  names = $redis.get(key)
  if names.nil?
    names = get_slack_names_hash(user_id)
    $redis.setex(key, 60*60*24*30, names.to_json)
  else
    names = JSON.parse(names)
  end
  if options[:use_real_name]
    name = names["real_name"].nil? ? names["name"] : names["real_name"]
  else
    name = names["first_name"].nil? ? names["name"] : names["first_name"]
  end
  name
end

# Makes an API request to Slack to get a user's set of names.
# (Slack's outgoing webhooks only send the user ID, so we need this to
# make the bot reply using the user's actual name.)
# 
def get_slack_names_hash(user_id)
  uri = "https://slack.com/api/users.list?token=#{ENV["API_TOKEN"]}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    user = response["members"].find { |u| u["id"] == user_id }
    names = { :id => user_id, :name => user["name"]}
    unless user.nil? || user["profile"].nil?
      names["real_name"] = user["profile"]["real_name"] unless user["profile"]["real_name"].nil? || user["profile"]["real_name"] == ""
      names["first_name"] = user["profile"]["first_name"] unless user["profile"]["first_name"].nil? || user["profile"]["first_name"] == ""
      names["last_name"] = user["profile"]["last_name"] unless user["profile"]["last_name"].nil? || user["profile"]["last_name"] == ""
    end
  else
    names = { :id => user_id, :name => "Sean Connery" }
  end
  names
end

def respond_with_what(params)
  name = get_slack_name(params[:user_id])
  "What do you want #{name}? I don't understand what you said. Beep boop."
end

def respond_with_help
  bot_username = ENV['BOT_USERNAME']
  reply = <<END
Type `#{bot_username} help` to see the message you're currently looking at.
Type `#{bot_username} show` to show the upcoming days that have already been clamied.
Type `#{bot_username} claim <date>` to claim a date. e.g. `#{bot_username} claim next wednesday` or `#{bot_username} claim 2016-05-08`.
Type `#{bot_username} unclaim <date>` to un-claim a date.
END
end

def get_user_on_date(date)
  key = "claimed_date:#{date}"
  $redis.get(key)
end

def remove_claim(date)
  key = "claimed_date:#{date}"
  $redis.del(key)
end

# Responds with a list of upcoming claimed spots
def respond_with_list
  claims = []
  $redis.scan_each(:match => "claimed_date:*") { |key|
    claimed_date = key.gsub("claimed_date:", "")

    user_id = get_user_on_date(claimed_date)

    if user_id.nil? || Date.parse(claimed_date) < Date.new
      remove_claim(claimed_date)
    else
      claims.insert(find_claim_insert(claims, claimed_date), { date: claimed_date, user_id: user_id })
    end
  }

  if claims.empty?
    "There are no upcoming claims."
  else
    claims.map {|claim| name = get_slack_name(claim[:user_id]); "#{claim[:date]} - #{name}"}.join("\n")
  end
end

def find_claim_insert(claims, claimed_date)
  claims.each_with_index do |claim, index|
    if Date.parse(claim[:date]) > Date.parse(claimed_date)
      return index
    end
  end

  claims.length
end

def is_channel_blacklisted?(channel_name)
  !ENV["CHANNEL_BLACKLIST"].nil? && ENV["CHANNEL_BLACKLIST"].split(",").find{ |a| a.gsub("#", "").strip == channel_name }
end

def format_date_for_response(date)
  date.strftime('%Y-%m-%d')
end

def format_date_for_key(date)
  date.strftime('%Y-%m-%d')
end

def parse_date_string(date_string)
  Chronic.parse(date_string, { context: :future })
end

def respond_error
  "Sorry, but I'm not sure what to do with that. Me bad robot. Beep boop :("
end

def respond_with_new_claim(params, date_to_claim)
  date = parse_date_string(date_to_claim)
  if date.nil?
    return respond_error
  end
  key = "claimed_date:#{format_date_for_key(date)}"
  name = get_slack_name(params[:user_id])

  if(current_owner_id = $redis.get(key))
    if current_owner_id == params[:user_id]
      return "Uhhh, sorry #{name}, but you've already claimed the spot for that day. Did you forget or am I just a dumb robot? Beep boop."
    end

    claimed_user = get_slack_name(current_owner_id)
    return "Sorry #{name}, but the spot is already claimed on that day by #{claimed_user}"
  end

  $redis.set(key, params[:user_id])
  "Done! @#{name} - you have claimed #{format_date_for_response(date)}"
rescue Exception => e
  puts "[ERROR] #{e}"
  respond_error
end

def respond_with_unclaim(params, date_to_unclaim)
  date = parse_date_string(date_to_unclaim)
  if date.nil?
    return respond_error
  end

  key = "claimed_date:#{format_date_for_key(date)}"
  name = get_slack_name(params[:user_id])

  if(current_owner_id = $redis.get(key))
    if current_owner_id == params[:user_id]
      remove_claim(format_date_for_key(date))
      return "Done! The parking spot is now free on #{format_date_for_response(date)}"
    end

    claimed_user = get_slack_name(current_owner_id)
    return "Sorry, but #{claimed_user} has the spot for that day. They need to unclaim it. Beep boop."
  end

  return "Looks like the spot is already unclaimed on that day."
rescue Exception => e
  puts "[ERROR] #{e}"
  respond_error
end

# Handles the post request made by the slack outgoing webhook
# Params sent:
#
# ???
# token=abc123
# team_id=T0001
# channel_id=C123456
# channel_name=test
# user_id=U123456
# user_name=Mike
# text=parkingbot show
# trigger_word=parkingbot
#
post "/" do
  begin
    puts "[LOG] #{params}"
    params[:text] = params[:text].sub(params[:trigger_word], "").strip

    if params[:token] != ENV["OUTGOING_WEBHOOK_TOKEN"]
      response = "Bad token"
    elsif is_channel_blacklisted?(params[:channel_name])
      response = "Sorry, but I can't respond in this channel"
    elsif params[:text].match(/^help$/i)
      response = respond_with_help
    elsif params[:text].match(/^show$/i) || params[:text].match(/^list$/i)
      response = respond_with_list
    elsif match = params[:text].match(/^claim (.*)$/i)
      response = respond_with_new_claim(params, match[1])
    elsif match = params[:text].match(/^unclaim (.*)$/i)
      response = respond_with_unclaim(params, match[1])
    else
      response = respond_with_what(params)
    end

  rescue => e
    puts "[ERROR] #{e}"
  end

  status 200
  body json_response_for_slack(response)
end
