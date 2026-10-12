# frozen_string_literal: true

# Relative links in the Markdown files shipped in the gem must resolve to real
# files, and to files that are themselves shipped, so the installed docs work
# offline and on GitHub at any tag. Links to files deliberately kept out of the
# gem are listed in REPO_ONLY as [document, target] pairs, and each such
# document must say, where it links the target, that the target is repo-only.
require 'spec_helper'

module DocumentationLinks
  PROJECT_ROOT = File.expand_path('..', __dir__)
  ENSEMBLE_RESULT = 'examples/results/recommend-model-ensemble-code-review.md'
  REPO_ONLY = [
    ['README.md', ENSEMBLE_RESULT],
    ['examples/prompts/recommend-model-ensemble-prompt.md', ENSEMBLE_RESULT],
  ].freeze
  # Tracked Markdown deliberately kept out of the gem (spec/ is never packaged).
  UNPACKAGED = ['REVIEW_NOTES.md', ENSEMBLE_RESULT].freeze
  # Gem::Specification.load warns and returns nil when the gemspec raises.
  PACKAGED = (Gem::Specification.load(File.join(PROJECT_ROOT, 'agent-council.gemspec')) ||
              raise('agent-council.gemspec failed to load; see the warning above')).files.freeze
  # What a document must say, in the paragraph linking a REPO_ONLY target.
  REPO_ONLY_NOTICE = /source repository only|not (?:included )?in the gem/

  # Repo-relative paths of the relative link targets in doc (anchors dropped).
  def self.targets(doc)
    targets_in(File.read(File.join(PROJECT_ROOT, doc), encoding: 'UTF-8'), doc)
  end

  def self.targets_in(text, doc)
    text.scan(/\]\(([^)\s]+)\)/).flatten
      .grep_v(%r{\A(?:[a-z]+:|#)}i)
      .map do |target|
        path = File.expand_path(target.sub(/#.*\z/, ''), File.join(PROJECT_ROOT, File.dirname(doc)))
        path.delete_prefix("#{PROJECT_ROOT}/")
      end
  end

  # The blank-line-separated paragraphs of doc that link to target.
  def self.paragraphs_linking(doc, target)
    File.read(File.join(PROJECT_ROOT, doc), encoding: 'UTF-8').split(/\n\s*\n/).select do |paragraph|
      targets_in(paragraph, doc).include?(target)
    end
  end

  def self.packaged?(path)
    PACKAGED.include?(path) || PACKAGED.any? { |f| f.start_with?("#{path}/") }
  end
end

RSpec.describe 'packaged documentation links' do
  # Catches a new document left out of the gemspec's patterns, which the link
  # checks below can't, since they scan only files already packaged.
  it 'packages every tracked Markdown file not listed as deliberately unpackaged' do
    tracked = Dir.chdir(DocumentationLinks::PROJECT_ROOT) { `git ls-files -z -- '*.md'` }
      .split("\x0").grep_v(%r{\Aspec/})
    expect(tracked - DocumentationLinks::UNPACKAGED - DocumentationLinks::PACKAGED).to be_empty
  end

  # Sample prompts and configs ship so installed users can run them; only
  # generated sample output (examples/results/) stays out of the gem.
  it 'packages every tracked example except sample results' do
    tracked = Dir.chdir(DocumentationLinks::PROJECT_ROOT) { `git ls-files -z -- examples` }
      .split("\x0").grep_v(%r{\Aexamples/results/})
    expect(tracked - DocumentationLinks::PACKAGED).to be_empty
  end

  it 'does not package the files listed as deliberately unpackaged' do
    expect(DocumentationLinks::UNPACKAGED & DocumentationLinks::PACKAGED).to be_empty
  end

  DocumentationLinks::REPO_ONLY.each do |doc, target|
    it "#{doc} says, where it links #{target}, that it is not in the gem" do
      paragraphs = DocumentationLinks.paragraphs_linking(doc, target)
      expect(paragraphs).not_to be_empty, "#{doc} no longer links #{target}; drop it from REPO_ONLY"
      expect(paragraphs).to all(match(DocumentationLinks::REPO_ONLY_NOTICE)),
        "#{doc}: link to #{target} lacks a repo-only notice"
    end
  end

  DocumentationLinks::PACKAGED.grep(/\.md\z/).each do |doc|
    it "#{doc} has only relative links to existing, packaged files" do
      DocumentationLinks.targets(doc).each do |path|
        exists = File.exist?(File.join(DocumentationLinks::PROJECT_ROOT, path))
        expect(exists).to be(true), "#{doc}: missing #{path}"
        next if DocumentationLinks::REPO_ONLY.include?([doc, path])

        expect(DocumentationLinks.packaged?(path)).to be(true), "#{doc}: #{path} is not packaged in the gem"
      end
    end
  end
end
