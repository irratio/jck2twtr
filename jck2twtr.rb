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
      checkinterval: 900,
      noreposttag: "notwi"
    }
  end

  def initialize(options = {})
    @last_post_time = DateTime.now

    @options = default_options
    @options[:configfile] = options[:configfile] if options.has_key?(:configfile)

    config_file = YAML.load_file(@options[:configfile])

    @options.merge!(config_file['main'].inject({}){|resulthash,(k,v)| resulthash[k.to_sym] = v; resulthash})
    # reading options from config file, converting string keys to symbols in process

    @options.merge!(options)

    if @options.has_key?(:username) and ! @options.has_key?(:rssurl)
      @options[:rssurl] = "http://rss.juick.com/#{@options[:username]}/blog"
    end

    @options[:checkinterval] = @options[:checkinterval].to_i
    # just in case

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
        tags = []
        item.css('category').each do |c|
          tags << Unicode::downcase(c.text)
        end

        text = text.split(' ').map do |w|
          if tags.include?(Unicode::downcase(w))
            tags.delete(Unicode::downcase(w))
            '#' + w
          else
            w
          end
        end.join(" ")

        "#{link} #{media} #{text} #{tags.map {|t| "#"+t}.join(' ')}"
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

        if Twitter.update(tweet)
          @last_post_time = DateTime.now
        end
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
    options[:username] = f
    #options[:rssurl] = "http://rss.juick.com/#{options[:username]}/blog"
  end

  opts.on( '-r', '--rss-url URL', "RSS URL to parse (default: http://rss.juick.com/USERNAME/blog)" ) do |f|
    options[:rssurl] = f
  end

  opts.on( '-i', '--check-interval SECONDS', "Check interval in seconds, default 900 (15 min)" ) do |f|
    options[:checkinterval] = f.to_i
  end

  opts.on( '-s', '--shrtfy STRING', 'Shrtfy post text? May be "always" (default), "never" or "if-needed"' ) do |f|
    options[:shrtfy] = f
  end

  opts.on( '-t', '--add-hashtags STRING', 'Convert juick tags to twitter hashtags? May be "always", "never" (default) of "if-possible"') do |f|
    options[:addhashtags] = f
  end

  opts.on( '-n', '--norepost-tag STRING', 'Special juick tag for no repost. Default: notwi') do |f|
    options[:noreposttag] = f
  end


end

optparse.parse!

Process.daemon(false,1)

j2t = Jck2Twtr.new(options)
j2t.run!