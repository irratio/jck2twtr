# coding: utf-8
require "rubygems"
require "bundler/setup"
require "nokogiri"
require "open-uri"
require "twitter"
require "unicode"
require "yaml"
require "optparse"
require "date"

class Jck2Twtr
  def default_options
    {
      configfile: "config.yml",
      checkinterval: 720
    }
  end
  
  def initialize(options = {})
    @last_post_time = DateTime.now

    @options = default_options.merge(options)
    puts @options.inspect
    config_file = YAML.load_file(@options[:configfile])

    Twitter.configure do |config|
      config_file['twitter'].each do |key, value|
        config.instance_variable_set("@#{key}", value)
      end
    end
    
    unless @options.include? :rssurl
      puts "RSS URL is not set"
      exit
    end
  end

  def parse_rss
    doc = Nokogiri::XML(open(@options[:rssurl]))
    items = doc.css('item')
    
    items.map do |item|
      if DateTime.parse(item.css('pubDate').text) < @last_post_time
        nil
      else
        description = Nokogiri::HTML(item.css('description').text)

        description.css('a').each do |a|
          a.replace(a['href'])
        end

        description.css('br').each do |br|
          br.replace(' ')
        end

        media = (item.xpath('media:content').first || {})['url']
        text = description.xpath("//text()").to_s
        link = item.css('link').text

        "#{link} #{media} #{text}"
      end
    end.reject(&:nil?)
  end

  def create_tweet(item)
    tweet_real_length = 0
    tweet = []

    item.split(' ').each do |word|
      if word.start_with? 'http'
        word_length = 20
      else
        word_capitalized = Unicode::upcase(word.chr) == word.chr
        word = word.gsub /[аеиоуыэюяьъ]+([^ \).,;:…!?»-])/i, '\1'  if word.length > 3
        word = word.gsub /["«».,;:…—-]+/, ''
        word_length = word.length
        word = "#{Unicode::upcase(word.chr)}#{word[1..-1]}" if word_capitalized
      end

      next if word_length == 0

      if (tweet_real_length + word_length) <= 140
        tweet_real_length += word_length + 1
        tweet<< word
      else
        break
      end
    end

    tweet.join(" ")
  end

  def run!
    while true do
      parse_rss.map { |item| create_tweet(item) }.each do |tweet|
        puts tweet

        #if Twitter.update(tweet)
          @last_post_time = DateTime.now
        # end
      end
      sleep(@options[:checkinterval])
    end
  end

end

options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Usage: jck2twtr [-h] [-c] [-u] [-r]"
  opts.on( '-h', '--help', 'Display this screen' ) do
    puts opts
    exit
  end

  opts.on( '-c', '--config FILE', "Config file" ) do |f|
    options[:configfile] = f
  end

  opts.on( '-u', '--juick-username USERNAME', "Username on Juick" ) do |f|
    puts f.inspect
    options[:username] = f
    options[:rssurl] = "http://rss.juick.com/#{options[:username]}/blog"
  end

  opts.on( '-r', '--rss-url URL', "RSS URL to parse (default: http://rss.juick.com/USERNAME/blog)" ) do |f|
    options[:rssurl] = f
  end

  opts.on( '-i', '--check-interval SECONDS', "Check interval in seconds, default 720 (15 min)" ) do |f|
    options[:checkinterval] = f.to_i
  end
end

optparse.parse!

Process.daemon(false,1)

j2t = Jck2Twtr.new(options)
j2t.run!