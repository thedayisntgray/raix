# frozen_string_literal: true

class MeaningOfLife
  include Raix::ChatCompletion

  def initialize
    self.model = "meta-llama/llama-3-8b-instruct:free"
    self.seed = 9999 # try to get reproduceable results
    transcript << { user: "What is the meaning of life?" }
  end
end

class InfiniteLooper
  include Raix::ChatCompletion
  include Raix::FunctionDispatch

  attr_reader :call_count

  function :forever_loop, "A function that keeps looping" do |arguments|
    @call_count ||= 0
    @call_count += 1
    "Loop iteration #{@call_count}"
  end

  def initialize
    self.model = "meta-llama/llama-3-8b-instruct:free"
    self.seed = 9999
    transcript << { system: "Always call the forever_loop function. Never provide a text response." }
    transcript << { user: "Let's test the loop functionality." }
  end
end

RSpec.describe MeaningOfLife, :vcr do
  subject { described_class.new }

  it "does a completion with OpenAI" do
    expect(subject.chat_completion(openai: "gpt-4o")).to include("meaning of life is")
  end

  it "does a completion with OpenRouter" do
    expect(subject.chat_completion).to include("meaning of life is")
  end

  context "with predicted outputs" do
    let(:completion) { subject.chat_completion(openai: "gpt-4o", params: { prediction: }) }
    let(:prediction) do
      "THE MEANING OF LIFE CAN VARY GREATLY FROM PERSON TO PERSON, OFTEN INVOLVING THE PURSUIT OF HAPPINESS, CARE OF OTHERS, AND PERSONAL GROWTH!."
    end
    let(:response) { Thread.current[:chat_completion_response] }

    before do
      subject.transcript.clear
      subject.transcript << { system: "Answer the user question in ALL CAPS." }
      subject.transcript << { user: "WHAT IS THE MEANING OF LIFE?" }
    end

    it "does a completion with OpenAI" do
      expect(completion).to start_with("THE MEANING OF LIFE")
      expect(response.dig("usage", "completion_tokens_details", "accepted_prediction_tokens")).to be > 0
      expect(response.dig("usage", "completion_tokens_details", "rejected_prediction_tokens")).to be > 0
    end
  end
end

RSpec.describe "Circuit Breakers", :vcr do
  describe "loop iteration limit" do
    subject { InfiniteLooper.new }

    it "trips the circuit breaker after maximum iterations" do
      # We'll mock the chat completion response to simulate a model that keeps making function calls
      allow(subject).to receive(:openai_request).and_return({
        "choices" => [
          {
            "message" => {
              "tool_calls" => [
                {
                  "function" => {
                    "name" => "forever_loop",
                    "arguments" => "{}"
                  }
                }
              ]
            }
          }
        ]
      })

      expect {
        subject.chat_completion(openai: "gpt-4o", loop: true)
      }.to raise_error(Raix::CircuitBreakerTrippedError, /Maximum loop iteration count/)
      
      # Verify we looped the expected number of times
      expect(subject.instance_variable_get(:@loop_iteration_count)).to eq(Raix::ChatCompletion::MAX_LOOP_ITERATIONS)
    end
    
    it "resets the loop counter when getting a content response" do
      # Set the loop counter directly to simulate previous increments
      subject.instance_variable_set(:@loop_iteration_count, 5)
      
      # Check that the counter was set correctly
      expect(subject.instance_variable_get(:@loop_iteration_count)).to eq(5)
      
      # Now return a content response which should reset the counter
      allow(subject).to receive(:openai_request).and_return({
        "choices" => [
          {
            "message" => {
              "content" => "This is a text response"
            }
          }
        ]
      })
      
      subject.chat_completion(openai: "gpt-4o", loop: true)
      
      # Verify the counter was reset
      expect(subject.instance_variable_get(:@loop_iteration_count)).to eq(0)
    end
  end

  describe "conversation turn limit" do
    subject { InfiniteLooper.new }
    
    it "trips the circuit breaker after maximum conversation turns" do
      # Fill the transcript with dummy messages to reach the limit
      (Raix::ChatCompletion::MAX_CONVERSATION_TURNS - subject.transcript.size).times do |i|
        subject.transcript << { user: "Dummy message #{i}" }
      end
      
      expect {
        subject.chat_completion(openai: "gpt-4o")
      }.to raise_error(Raix::CircuitBreakerTrippedError, /Maximum conversation turn count/)
    end
    
    it "can reset circuit breakers manually" do
      # Set the loop counter to a high value
      subject.instance_variable_set(:@loop_iteration_count, Raix::ChatCompletion::MAX_LOOP_ITERATIONS - 1)
      
      # Reset the circuit breakers
      subject.reset_circuit_breakers!
      
      # Verify the counter was reset
      expect(subject.instance_variable_get(:@loop_iteration_count)).to eq(0)
    end
  end
end
