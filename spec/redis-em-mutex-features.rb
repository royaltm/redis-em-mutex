$:.unshift "lib"
require 'em-synchrony'
require 'redis-em-mutex'

describe Redis::EM::Mutex do

  it "should raise MutexError while redis server not found on setup" do
    expect {
      described_class.setup(host: 'abcdefghijklmnopqrstuvwxyz', reconnect_max: 0)
    }.to raise_error(described_class::MutexError, /Can not establish watcher channel connection!/)

    expect {
      described_class.setup(host: '255.255.255.255', reconnect_max: 0)
    }.to raise_error(described_class::MutexError, /Can not establish watcher channel connection!/)

    expect {
      described_class.setup(port: 65535, reconnect_max: 0)
    }.to raise_error(described_class::MutexError, /Can not establish watcher channel connection!/)
  end

  around(:each) do |testcase|
    @after_em_stop = nil
    ::EM.synchrony do
      begin
        testcase.call
      ensure
        ::EM.stop
      end
    end
    @after_em_stop.call if @after_em_stop
  end

end
