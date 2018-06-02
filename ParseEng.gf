--# -path=.:../abstract:../common:../api
concrete ParseEng of Parse =
  NounEng,
  VerbEng - [PassV2],
  AdjectiveEng,
  AdverbEng,
  NumeralEng,
  SentenceEng,
  QuestionEng,
  RelativeEng,
  ConjunctionEng,
  PhraseEng,
  TextX - [Pol,PPos,PNeg,SC],
  IdiomEng,
  TenseX - [Pol,PPos,PNeg,SC],
  ParseExtendEng,
  WordNetEng,
  DocumentationEng
  ** open MorphoEng, ResEng, ParadigmsEng, IrregEng, (E = ExtraEng), (S = SyntaxEng), Prelude in {

lin
  PPos = {s = [] ; p = CPos} ;
  PNeg = {s = [] ; p = CNeg True} ; -- contracted: don't

-- INJECT

} ;
