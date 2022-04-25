require 'rails_helper'
require 'huginn_agent/spec_helper'

describe Agents::TwitchAgent do
  before(:each) do
    @valid_options = Agents::TwitchAgent.new.default_options
    @checker = Agents::TwitchAgent.new(:name => "TwitchAgent", :options => @valid_options)
    @checker.user = users(:bob)
    @checker.save!
  end

  pending "add specs here"
end
