# coding: utf-8
require "rubygems"
require "bundler/setup"
require "nokogiri"
require 'open-uri'

# Get a Nokogiri::HTML:Document for the page we’re interested in...

doc = Nokogiri::XML(open('http://rss.juick.com/Irregular/blog'))
items = doc.css('item')

items.each do |item|
  description = Nokogiri::HTML(item.css('description').text)

  description.css('a').each do |a|
    a.replace(a['href'])
  end

  media = (item.xpath('media:content').first || {})['url']
  text = description.xpath("//text()").to_s
  link = item.css('link').text

  tweet = "#{link} #{media} #{text}".split(' ').map do |word|
    if word.start_with? 'http'
      word
    else
      word.gsub /[аеиоуыэюяьъ]+([^ .,;:…!?-])/ do |s| $1 end
    end
  end.join(' ').gsub(/ +/, ' ')
  puts tweet
end
