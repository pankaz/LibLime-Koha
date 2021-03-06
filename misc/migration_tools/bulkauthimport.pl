#!/usr/bin/env perl
# small script that import an iso2709 file into koha 2.0

use strict;
BEGIN {
    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin;
    eval { require "$FindBin::Bin/kohalib.pl" };
}

# Koha modules used
use Unicode::Normalize;
use MARC::File::USMARC;
use MARC::File::XML;
use MARC::Record;
use MARC::Batch;
use Koha;
use C4::Context;
use C4::Charset;
use Koha::BareAuthority;
use Time::HiRes qw(gettimeofday);
use Getopt::Long;
use IO::File;

my ( $input_marc_file, $number) = ('',0);
my ($version, $delete, $test_parameter,$char_encoding, $verbose, $format, $commit);
$| = 1;
GetOptions(
    'file:s'    => \$input_marc_file,
    'n:i' => \$number,
    'h' => \$version,
    'd' => \$delete,
    't' => \$test_parameter,
    'c:s' => \$char_encoding,
    'v:s' => \$verbose,
    'm:s' => \$format,
    'commit:f' => \$commit,
);

if ($version || ($input_marc_file eq '')) {
    print <<EOF
small script to import an iso2709 file into Koha.
parameters :
\th : this version/help screen
\tfile /path/to/file/to/dump : the file to dump
\tv : verbose mode. Valid modes are 1 and 2
\tn : the number of the record to import. If missing, the whole file is imported
\tt : test mode : parses the file, saying what it would do, but doing nothing.
\tc : the MARC flavour. At the moment, MARC21 and UNIMARC supported. MARC21 by default.
\td : delete EVERYTHING related to authorities in koha-DB before import
\tm : format, MARCXML or ISO2709
\tcommit : the number of records to wait before performing a 'commit' operation
IMPORTANT : don't use this script before you've entered and checked twice (or more) your MARC parameters tables.
If you fail the test, the import won't work correctly and you will get invalid datas.

SAMPLE : ./bulkmarcimport.pl -file /home/paul/koha.dev/local/npl -n 1
EOF
;#'
die;
}

my $dbh = C4::Context->dbh;

if ($delete) {
    print "deleting authorities\n";
    $dbh->do("truncate auth_header");
}
if ($test_parameter) {
    print "TESTING MODE ONLY\n    DOING NOTHING\n===============\n";
}

my $marcFlavour = C4::Context->preference('marcflavour') || 'MARC21';
$char_encoding = 'MARC21' unless ($char_encoding);
print "CHAR : $char_encoding\n" if $verbose;
my $starttime = gettimeofday;
my $fh = IO::File->new($input_marc_file); # don't let MARC::Batch open the file, as it applies the ':utf8' IO layer
my $batch;
if ($format =~ /XML/i) {
    # ugly hack follows -- MARC::File::XML, when used by MARC::Batch,
    # appears to try to convert incoming XML records from MARC-8
    # to UTF-8.  Setting the BinaryEncoding key turns that off
    # TODO: see what happens to ISO-8859-1 XML files.
    # TODO: determine if MARC::Batch can be fixed to handle
    #       XML records properly -- it probably should be
    #       be using a proper push or pull XML parser to
    #       extract the records, not using regexes to look
    #       for <record>.*</record>.
    $MARC::File::XML::_load_args{BinaryEncoding} = 'utf-8';
    $batch = MARC::Batch->new( 'XML', $fh );
} else {
    $batch = MARC::Batch->new( 'USMARC', $fh );
}
$batch->warnings_off();
$batch->strict_off();
my $i=0;

$dbh->{AutoCommit} = 0;
my $commitnum = 50;
if ($commit) {
    $commitnum = $commit;
}

RECORD: while ( my $record = $batch->next() ) {
    $i++;
    print ".";
    print "\r$i" unless $i % 100;

    if ($record->encoding() eq 'MARC-8') {
        my ($guessed_charset, $charset_errors);
        ($record, $guessed_charset, $charset_errors) = MarcToUTF8Record($record, $marcFlavour);
        if ($guessed_charset eq 'failed') {
            warn "ERROR: failed to perform character conversion for record $i\n";
            next RECORD;            
        }
    }
    warn "$i ==>".$record->as_formatted() if $verbose eq 2;

    unless ($test_parameter) {
        my $auth = Koha::BareAuthority->new(marc => $record);
        $auth->save;
        warn "ADDED authority NB ".$auth->id." in DB\n" if $verbose;
        $dbh->commit() if (0 == $i % $commitnum);
    }

    last if $i ==  $number;
}
$dbh->commit();

my $timeneeded = gettimeofday - $starttime;
print "\n$i MARC record done in $timeneeded seconds\n";
