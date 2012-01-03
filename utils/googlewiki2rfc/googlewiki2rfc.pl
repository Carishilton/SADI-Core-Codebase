#!/usr/bin/perl

use strict;
use warnings;
no warnings qw(once);
use autodie qw(:all);

use lib 'lib';
use constant::boolean;
use XML::Writer;
use Getopt::Long;
use URI;
use File::Temp qw(tempdir);
use File::Spec::Functions qw(splitpath catfile);
use IO::File;
use GoogleWiki2Markdown;
use Markdent::Parser;
use File::Slurp;

#----------------------------------------------------------------------
# constants
#----------------------------------------------------------------------

use constant TEMP_XML_FILE => 'temp.xml';
use constant TEMP_OUTPUT_FILE => 'temp.txt';

#----------------------------------------------------------------------
# parse command line args
#----------------------------------------------------------------------

use constant USAGE => <<'HEREDOC';
Usage: gcw2rfc.pl [options] <docname> front.xml [middle.wiki] [back.wiki] > rfc.txt

<docname> is a document identifier used in the RFC submission / editing process of the 
IETF.  It can be anything, but a typical example is: 'draft-bvandervalk-sadi-01'. 

"front.xml" contains metadata about the document (e.g. authors, abstract).

"middle.wiki" is a Google Wiki file containing the Table of Contents (in the form of a
bulleted list, possibly nested) for the main part of the document.

"back.wiki" is a Google Wiki file containing the Table of Contents for the end matter 
of the document (e.g. References).
HEREDOC

my $help_opt = FALSE;
my $trace_opt = FALSE;
my $rfc_xml_filename;

my $getopt_success = GetOptions(
    'trace' => \$trace_opt,
    'xml=s' => \$rfc_xml_filename,
    'help' => \$help_opt,
);

die USAGE."\n" unless $getopt_success;

if ($help_opt) {
    warn USAGE;
    exit 0;
}

die USAGE."\n" unless @ARGV >= 1;

my $doc_name = $ARGV[0];
my $front_file = $ARGV[1];
my $middle_file = $ARGV[2];
my $back_file = $ARGV[3];

$::RD_ERRORS = 1;
$::RD_TRACE = 1 if $trace_opt;
$::RD_HINT = 1 if $trace_opt;

#----------------------------------------------------------------------
# main
#----------------------------------------------------------------------

# temp input/output files, because xml2rfc.tcl doesn't do STDIN/STDOUT

my $tempdir = tempdir(CLEANUP => 1);
$rfc_xml_filename ||= catfile($tempdir, TEMP_XML_FILE);
my $rfc_xml_file = IO::File->new($rfc_xml_filename, '>');
my $temp_output_filename = catfile($tempdir, TEMP_OUTPUT_FILE);

# translate Google Wiki doc hierarchy => RFC XML

my $xml_writer = new XML::Writer(
    OUTPUT => $rfc_xml_file, 
    UNSAFE => 1,               # allows us to insert front.xml verbatim
    DATA_MODE => 1,            # newlines after tags
    DATA_INDENT => 2,          # proper indentation
);

$xml_writer->xmlDecl();
$xml_writer->doctype('rfc', undef, 'rfc2629.dtd');
$xml_writer->pi('rfc', 'toc="yes"');       # automatically build a table of contents 
$xml_writer->pi('rfc', 'symrefs="yes"');   # use anchors instead of numbers for references
$xml_writer->pi('rfc', 'compact="yes"');   # conserve vertical whitespace 
$xml_writer->pi('rfc', 'subcompact="no"'); # but keep a blank line between list items 
$xml_writer->startTag('rfc', ipr => 'full3978', docName => "$doc_name");

$xml_writer->startTag('front');
open(my $front_fh, '<', $front_file);
$xml_writer->raw(join('',<$front_fh>));
close($front_fh);
$xml_writer->endTag('front');

$xml_writer->startTag('middle');
#wiki_toc_to_xml($xml_writer, $middle_file) if $middle_file;
wiki_toc_to_xml($xml_writer, $middle_file) if $middle_file;
$xml_writer->endTag('middle');

$xml_writer->startTag('back');
wiki_toc_to_xml($xml_writer, $back_file) if $back_file;
$xml_writer->endTag('back');

$xml_writer->endTag('rfc');
$xml_writer->end();
$rfc_xml_file->close();

if ($trace_opt) {
    warn "XML output:\n";
    open (my $xml_fh, '<', $rfc_xml_filename);
    warn $_ while (<$xml_fh>);
    close($xml_fh);
    warn "\n";
}

# translate RFC XML => RFC text file

system(
    'tclsh', 
    'xml2rfc.tcl', 
    'xml2rfc', 
    $rfc_xml_filename, 
    $temp_output_filename
);

# send output to STDOUT

open (my $output_fh, '<', $temp_output_filename);
print while (<$output_fh>);
close($output_fh);

#----------------------------------------------------------------------
# callbacks from wiki parser (generates RFC XML)
#----------------------------------------------------------------------

sub wiki_toc_to_xml {

    my ($xml_writer, $wiki_file) = @_;
    
    my $working_dir = (splitpath($wiki_file))[1];
    my $input = read_file($wiki_file);
    my $page = filename_to_wiki_page($wiki_file);

    # create a class containing parser callbacks
    eval {

        package Markdent::Handler::TOC;

        use strict; 
        use warnings;

        use URI;
        use Moose;
        use GoogleWiki2Markdown;
        use constant::boolean;

        with 'Markdent::Role::EventsAsMethods';

        our $AUTOLOAD; 
        sub AUTOLOAD { 
#            ::trace(sprintf('unhandled event %s with args (%s)', $AUTOLOAD, join(', ', @_))); 
        }

        sub new {
            my ($class, $xml_writer, $working_dir, $page) = @_;
            my $self = {
                xml_writer => $xml_writer,
                working_dir => $working_dir,
                list_level => 0,
                visited => {$page => 1},      # visited pages or sections of pages
                skip_item => FALSE,
                in_link => FALSE,
            };
            return bless($self, $class);
        }

        sub start_unordered_list { 
            $_[0]->{list_level}++; 
        }

        sub end_unordered_list { 
            $_[0]->{list_level}--; 
        }

        sub end_list_item {
            my $self = shift;
            $self->{xml_writer}->endTag('section') unless $self->{skip_item};
            $self->{skip_item} = FALSE;
        }

        sub start_link { 
            my $self = shift;
            %_ = @_;
            my $uri = URI->new($_{uri});
            # if uri is relative
            if (!defined($uri->scheme())) {
                $self->{in_link} = TRUE;
                $self->{link_uri} = $uri;
           }
        }

        sub end_link {
           $_[0]->{in_link} = FALSE; 
        }

        sub text {

            my $self = shift;
            my $xml_writer = $self->{xml_writer};
            my $visited = $self->{visited};
            my $text = ::trim($_[1]);
            
            # ignore whitespace text events (e.g. newlines at end of list items)
            return unless $text; 

            my $in_link = $self->{in_link};
            my $anchor = $in_link ? $self->{link_uri}->as_string : main::get_anchor('',$text);

#            ::tracef('anchor: \'%s\'', $anchor);
#            ::tracef('visited? %s', ($visited->{$anchor} ? 'yes' : 'no'));
#            ::tracef('visited: (%s)', join(',', %$visited));

            if ($visited->{$anchor}) {
                $self->{skip_item} = TRUE;
                ::tracef('skipping TOC entry %s, page/section already visited', $anchor);
                return;
            }

            $xml_writer->startTag('section', anchor => $anchor, title => $text);
           
            if ($in_link) {
                ::trace("following TOC link: $_{uri}");
                ::wiki_to_xml(
                    $xml_writer, 
                    $self->{working_dir},
                    $self->{visited}, 
                    $self->{link_uri}->path, # page
                    ($self->{list_level} - 1),
                    $self->{link_uri}->fragment # section (optional)
                );
            }

        }

        package __PACKAGE__; 

    };

    die $@ if $@;

    my $markdown = GoogleWiki2Markdown::convert($input);
#    printf("markdown:\n%s\n", $markdown);
    my $handler = Markdent::Handler::TOC->new($xml_writer, $working_dir, $page);
    my $parser = Markdent::Parser->new(handler => $handler);
    $parser->parse(markdown => $markdown);

}

sub wiki_to_xml {
    
    my ($xml_writer, $working_dir, $visited, $page, $section_level_offset, $section) = @_;

    my $uri = $section ? get_anchor($page, $section) : $page;

    if ($visited->{$uri}) {
        trace(sprintf('skipping %s, page/section already visited', $uri));
        return;
    }

    trace(sprintf('visiting %s', $uri));
    $visited->{$uri} = 1;

    my $input = read_file(wiki_page_to_filename($working_dir, $page));

    # create a class containing parser callbacks
    eval {

        package Markdent::Handler::Page;

        use strict; 
        use warnings;

        use constant::boolean;
        use Moose;

        with 'Markdent::Role::EventsAsMethods';

        our $AUTOLOAD; 
        sub AUTOLOAD { 
#            ::trace(sprintf('unhandled event %s with args (%s)', $AUTOLOAD, join(', ', @_))); 
        }

        sub new {
            my ($class, $xml_writer, $visited, $page, $section_level_offset, $section) = @_;
            my $self = {
                xml_writer => $xml_writer,
                visited => $visited,
                page => $page,
                section_level_offset => $section_level_offset,
                section => $section,
                open_sections => [],
                output_enabled => ($section ? 0 : 1),
                header_level => 0,
                first_section_on_page => TRUE,
                in_inline_code => FALSE,
            };
            return bless($self, $class);
        }

        sub output_enabled {
            my $self = $_[0];
            my $value = $_[1];
            $self->{output_enabled} = $value if defined($value);
            return $self->{output_enabled};
        }

        sub start_header { 
            $_[0]->{header_level} = $_[2];
        }

        sub end_header { 
            $_[0]->{header_level} = 0;
        }
        
        sub text {
            my $self = $_[0];
            my $text = $_[2];
            my $xml_writer = $self->{xml_writer};
            if ($self->{header_level}) {
                $self->header($self->{header_level}, $text); 
            } else {
                ::tracef('text event: \'%s\'', $text);
                $xml_writer->characters($text);
            }
        } 

        sub start_strong {
            $_[0]->{xml_writer}->characters('*');
        }

        sub end_strong {
            $_[0]->{xml_writer}->characters('*');
        }

        sub start_emphasis {
            $_[0]->{xml_writer}->characters('_');
        }

        sub end_emphasis {
            $_[0]->{xml_writer}->characters('_');
        }

        sub start_unordered_list {
            $_[0]->{xml_writer}->startTag('list', style => 'symbols');
        }

        sub end_unordered_list {
            $_[0]->{xml_writer}->endTag('list');
        }

        sub start_ordered_list {
            $_[0]->{xml_writer}->startTag('list', style => 'numbers');
        }

        sub end_ordered_list {
            $_[0]->{xml_writer}->endTag('list');
        }

        sub start_list_item {
            $_[0]->{xml_writer}->startTag('t');
        }

        sub end_list_item {
            $_[0]->{xml_writer}->endTag('t');
        }

        sub start_paragraph {
            my $self = $_[0];
            $self->{xml_writer}->startTag('t') unless $self->{in_inline_code};
        }

        sub end_paragraph {
            my $self = $_[0];
            $self->{xml_writer}->endTag('t') unless $self->{in_inline_code};
        }

        sub html_block {

            ::tracef("html_block event: (%s)\n", join(',',@_));

            my $xml_writer = $_[0]->{xml_writer};
            my $html = $_[2];
            
            # code blocks

            if ($html =~ /^\s*<pre>\s*<code>(.*?)<\/code>\s*<\/pre>\s*$/sm) {

                my $code = $1;

                $xml_writer->startTag('figure');
                $xml_writer->startTag('artwork');

                # separate code from preceding text/figure/list with blank line
                $code =~ s/^(.*\S.*)/\n$1/;

                # indent 6 spaces
                $code =~ s/^/' 'x6/emg;

                # wrap lines at 72 chars
#                $code =~ s/^(.{72})(.)/$1\n$2/mg;

                $xml_writer->characters($code);

                $xml_writer->endTag('artwork');
                $xml_writer->endTag('figure');

            }
        }

        sub header { 

            my ($self, $level, $header) = @_;

            $level += $self->{section_level_offset};
            $header = ::trim($header);

            my $xml_writer = $self->{xml_writer};
            my $visited = $self->{visited};
            my $page = $self->{page};
            my $anchor = ::get_anchor($page, $header);
            my $open_sections = $self->{open_sections};
            my $section = $self->{section};
           
            if ($section && ($anchor eq ::get_anchor($page, $section))) {
                $self->output_enabled(TRUE);
            } 

            unless ($self->output_enabled) {
                ::trace(sprintf('skipping %s, outside of section %s', $anchor, $section));
                return;
            }

            while(@$open_sections && ($open_sections->[-1] >= $level)) {
                $xml_writer->endTag('section');
                pop(@$open_sections);
            }
            
            # we only need to write out <section> start/end tags for subsections of $section.
            # The section tags for $section are handled in the parent (wiki_toc_to_xml).

            my $omit_section_tag = FALSE;
            if ($section) {
                $omit_section_tag = TRUE if ($anchor eq ::get_anchor($page, $section));
            } else {
                $omit_section_tag = TRUE if $self->{first_section_on_page};
            }

            ::tracef('visiting page section: %s', $anchor); 
            ::tracef('omitting section tag for %s', $anchor) if $omit_section_tag;
            
            unless ($omit_section_tag) {
                $xml_writer->startTag('section', anchor => $anchor, title => $header);
                push(@$open_sections, $level);
            }
            
            $visited->{$anchor} = 1;
            $self->{first_section_on_page} = FALSE;


        }

        sub end_document { 
            my $self = shift;
            my $open_sections = $self->{open_sections};
            while (pop(@$open_sections)) {
                $self->{xml_writer}->endTag('section');
            }
        }

        package __PACKAGE__; 

    };

    die $@ if $@;

    my $markdown = GoogleWiki2Markdown::convert($input);
#    ::tracef('input markdown: \'%s\'', $markdown) if $page =~ /synch/i;
    my $handler = Markdent::Handler::Page->new($xml_writer, $visited, $page, $section_level_offset, $section);
    my $parser = Markdent::Parser->new(handler => $handler);
    $parser->parse(markdown => $markdown);

}

#----------------------------------------------------------------------
# utility subs
#----------------------------------------------------------------------

sub get_anchor {
    my ($page, $section) = @_;
    $page ||= '';
    $section ||= '';
    my $anchor = "${page}#${section}";
    $anchor =~ s/ /_/g;
    return $anchor;
}

sub tracef {
    trace(sprintf(shift, @_)) if $trace_opt;
}

sub trace {
    warn sprintf("TRACE => %s\n", shift) if $trace_opt;
}

sub trace_sub_call {
    warn sprintf('%s: (%s)', shift, join(',', @_));
}

sub filename_to_wiki_page {
    my $page = (splitpath($_[0]))[2];
    $page =~ s/.wiki$//;
    return $page;
}

sub wiki_page_to_filename {
    return catfile($_[0], $_[1] . '.wiki');
}

sub trim {
    my $text = shift;
    $text =~ s/^\s*(.*?)\s*$/$1/; 
    return $text;
}

