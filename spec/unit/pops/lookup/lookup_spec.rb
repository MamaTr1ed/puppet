require 'spec_helper'
require 'puppet_spec/files'
require 'puppet/pops'
require 'deep_merge/core'

module Puppet::Pops
module Lookup
describe 'The lookup API' do
  include PuppetSpec::Files

  let(:env_name) { 'spec' }
  let(:code_dir) { Puppet[:environmentpath] }
  let(:env_dir) { File.join(code_dir, env_name) }
  let(:env) { Puppet::Node::Environment.create(env_name.to_sym, [File.join(populated_env_dir, 'modules')]) }
  let(:node) { Puppet::Node.new('test', :environment => env) }
  let(:compiler) { Puppet::Parser::Compiler.new(node) }
  let(:scope) { compiler.topscope }
  let(:invocation) { Invocation.new(scope) }

  let(:code_dir_content) do
    {
      'hiera.yaml' => <<-YAML.unindent,
        version: 5
        YAML
      'data' => {
        'common.yaml' => <<-YAML.unindent
          a: a (from global)
          d: d (from global)
          mod::e: mod::e (from global)
          YAML
      }
    }
  end

  let(:env_content) do
    {
      'hiera.yaml' => <<-YAML.unindent,
        version: 5
        YAML
      'data' => {
        'common.yaml' => <<-YAML.unindent
          b: b (from environment)
          d: d (from environment)
          mod::f: mod::f (from environment)
          YAML
      }
    }
  end

  let(:mod_content) do
    {
      'hiera.yaml' => <<-YAML.unindent,
        version: 5
        YAML
      'data' => {
        'common.yaml' => <<-YAML.unindent
          mod::c: mod::c (from module)
          mod::e: mod::e (from module)
          mod::f: mod::f (from module)
          YAML
      }
    }
  end

  let(:populated_env_dir) do
    all_content = code_dir_content.merge(env_name => env_content.merge('modules' => { 'mod' => mod_content }))
    dir_contained_in(code_dir, all_content)
    all_content.keys.each { |key| PuppetSpec::Files.record_tmp(File.join(code_dir, key)) }
    env_dir
  end

  before(:each) do
    Puppet[:hiera_config] = File.join(code_dir, 'hiera.yaml')
    Puppet.push_context(:loaders => Puppet::Pops::Loaders.new(env))
  end

  after(:each) do
    Puppet.pop_context
  end

  context 'when doing lookup' do
    it 'finds data in global layer' do
      expect(Lookup.lookup('a', nil, nil, false, nil, invocation)).to eql('a (from global)')
    end

    it 'finds data in environment layer' do
      expect(Lookup.lookup('b', nil, 'not found', true, nil, invocation)).to eql('b (from environment)')
    end

    it 'global layer wins over environment layer' do
      expect(Lookup.lookup('d', nil, 'not found', true, nil, invocation)).to eql('d (from global)')
    end

    it 'finds data in module layer' do
      expect(Lookup.lookup('mod::c', nil, 'not found', true, nil, invocation)).to eql('mod::c (from module)')
    end

    it 'global layer wins over module layer' do
      expect(Lookup.lookup('mod::e', nil, 'not found', true, nil, invocation)).to eql('mod::e (from global)')
    end

    it 'environment layer wins over module layer' do
      expect(Lookup.lookup('mod::f', nil, 'not found', true, nil, invocation)).to eql('mod::f (from environment)')
    end

    context "with 'global_only' set to true in the invocation" do
      let(:invocation) { Invocation.new(scope).set_global_only }

      it 'finds data in global layer' do
        expect(Lookup.lookup('a', nil, nil, false, nil, invocation)).to eql('a (from global)')
      end

      it 'does not find data in environment layer' do
        expect(Lookup.lookup('b', nil, 'not found', true, nil, invocation)).to eql('not found')
      end

      it 'does not find data in module layer' do
        expect(Lookup.lookup('mod::c', nil, 'not found', true, nil, invocation)).to eql('not found')
      end
    end

    context "with 'global_only' set to true in the lookup adapter" do
      it 'finds data in global layer' do
        invocation.lookup_adapter.set_global_only
        expect(Lookup.lookup('a', nil, nil, false, nil, invocation)).to eql('a (from global)')
      end

      it 'does not find data in environment layer' do
        invocation.lookup_adapter.set_global_only
        expect(Lookup.lookup('b', nil, 'not found', true, nil, invocation)).to eql('not found')
      end

      it 'does not find data in module layer' do
        invocation.lookup_adapter.set_global_only
        expect(Lookup.lookup('mod::c', nil, 'not found', true, nil, invocation)).to eql('not found')
      end
    end

    context 'with subclassed lookup adpater' do
      let(:other_dir) { tmpdir('other') }
      let(:other_dir_content) do
        {
          'hiera.yaml' => <<-YAML.unindent,
            version: 5
            hierarchy:
              - name: Common
                path: common.yaml
              - name: More
                path: more.yaml
            YAML
          'data' => {
            'common.yaml' => <<-YAML.unindent,
              a: a (from other global)
              d: d (from other global)
              mixed_adapter_hash:
                a:
                  ab: value a.ab (from other common global)
                  ad: value a.ad (from other common global)
              mod::e: mod::e (from other global)
              lookup_options:
                mixed_adapter_hash:
                  merge: deep
              YAML
            'more.yaml' => <<-YAML.unindent
              mixed_adapter_hash:
                a:
                  aa: value a.aa (from other more global)
                  ac: value a.ac (from other more global)
              YAML
          }
        }
      end

      let(:populated_other_dir) do
        dir_contained_in(other_dir, other_dir_content)
        other_dir
      end

      before(:each) do
        eval(<<-RUBY.unindent)
        class SpecialLookupAdapter < LookupAdapter
           def initialize(compiler)
             super
             set_global_only
             set_global_hiera_config_path(File.join('#{populated_other_dir}', 'hiera.yaml'))
           end
        end
        RUBY
      end

      after(:each) do
        Puppet::Pops::Lookup.send(:remove_const, :SpecialLookupAdapter)
      end

      let(:other_invocation) { Invocation.new(scope, EMPTY_HASH, EMPTY_HASH, nil, SpecialLookupAdapter) }

      it 'finds different data in global layer' do
        expect(Lookup.lookup('a', nil, nil, false, nil, other_invocation)).to eql('a (from other global)')
        expect(Lookup.lookup('a', nil, nil, false, nil, invocation)).to eql('a (from global)')
      end

      it 'does not find data in environment layer' do
        expect(Lookup.lookup('b', nil, 'not found', true, nil, other_invocation)).to eql('not found')
        expect(Lookup.lookup('b', nil, 'not found', true, nil, invocation)).to eql('b (from environment)')
      end

      it 'does not find data in module layer' do
        expect(Lookup.lookup('mod::c', nil, 'not found', true, nil, other_invocation)).to eql('not found')
        expect(Lookup.lookup('mod::c', nil, 'not found', true, nil, invocation)).to eql('mod::c (from module)')
      end

      it 'resolves lookup options using the custom adapter' do
        expect(Lookup.lookup('mixed_adapter_hash', nil, 'not found', true, nil, other_invocation)).to eql(
          {
            'a' => {
              'aa' => 'value a.aa (from other more global)',
              'ab' => 'value a.ab (from other common global)',
              'ac' => 'value a.ac (from other more global)',
              'ad' => 'value a.ad (from other common global)'
            }
          }
        )
      end
    end
  end
end
end
end
