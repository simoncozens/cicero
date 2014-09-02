package Cicero;
use PDF::API2;
use strict;
use Text::KnuthPlass;
use Cicero::StreamParser;
use Cicero::KP;

use PDF::API2;
our ($pdf, $page, $font, $cursor_x, $cursor_y, $text);
our $stash = Template::Stash::Persistent->new();

sub begin {
    $pdf = PDF::API2->new(-file => $stash->get("output"));
    $pdf->mediabox($stash->get("pagesize"));
}

sub newpage {
    $page = $pdf->page;
    $text = $page->text;
    $stash->set("pageno", $stash->get("pageno")+1);
    shift->initialize(@_);
}

sub initialize {
    my ($self, %options) = @_;
    while (my ($k,$v) = each %options) { $stash->set($k,$v) }
    $cursor_x = $stash->get("left");
    $cursor_y = $stash->get("top");
    $text->lead($stash->get("lead"));
    Cicero->setfont();
}

my %fontcache;
my $lastfont;
my $lastsize;
my $lastcolor;

sub setfont {
    my ($self, $fontname, $fontsize, $color) = @_;
    $fontname = $stash->get("fontname") if !$fontname;
    $fontsize = $stash->get("fontsize") if !$fontsize;
    $text->fillcolor($color) if $color and $color ne $lastcolor;
    $lastcolor = $color;
    if (!$text->{' font'} or $fontname ne $lastfont or $fontsize != $lastsize) {
        $font = $fontcache{$fontname} ||= $pdf->ttfont($fontname);
        $text->font($font , $fontsize);
        $lastsize = $fontsize; $lastfont = $fontname;
        %Cicero::KP::widthcache = ();
    }
}

sub typeset {
    my $paragraph = shift;
    return unless $paragraph =~ /\S/;
    return unless $pdf;
    for (split /(\n\n)/, $paragraph) {
        if ($_ eq "\n\n") { 
            Cicero::KP->leave_hmode();
            Cicero::KP->add_parskip();
        } else { Cicero::KP->setpar($_) }
    }
}

sub glue    { push @Cicero::KP::nodes, Cicero::KP::Glue->new(@_)    }
sub vglue   { push @Cicero::KP::page, Cicero::KP::VGlue->new(@_)    }
sub penalty { push @Cicero::KP::nodes, Cicero::KP::Penalty->new(@_) }

sub finish {
    Cicero::KP->finish();
    $pdf->save;
}

1;
