# coding: utf-8
require "rubygems"
require "bundler/setup"
require "nokogiri"
require "open-uri"
require "twitter"
require "unicode"
require "yaml"

config_file = YAML.load_file("config.yml")

puts config_file.class
puts config_file.inspect

Twitter.configure do |config|
  config_file['twitter'].each do |key, value|
    config.instance_variable_set("@#{key}", value)
  end
  puts config.inspect
end

#Twitter.update("test tweet. like, really")

doc = Nokogiri::XML(open('http://rss.juick.com/Irregular/blog'))
items = doc.css('item')


items.each do |item|
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
  
  tweet_real_length = 0
  tweet = []
  "#{link} #{media} #{text}".split(' ').each do |word|
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
      #puts "2. #{word} #{tweet_real_length} #{word_length}"
      tweet<< word
    else
      #puts 'OMGWTF'
      break
    end
  end
  #.join(' ')#.gsub(/ +/, ' ')
  puts "TWEET:::#{tweet.join(" ")}:::"
  #Twitter.update(tweet.join(" ")
end
