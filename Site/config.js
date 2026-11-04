/* JARVIS settings. Fill these in from YOUR Supabase project:
   NEVER paste the service_role key here. */
window.JARVIS_CONFIG = {
  url: 'https://zmeochiojlspcziaqmry.supabase.co',
  anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InptZW9jaGlvamxzcGN6aWFxbXJ5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM1NjI1ODQsImV4cCI6MjEwOTEzODU4NH0.vScs873j8ESKN5ebsFZ0VMzmWcghu05PtPv1PD6ofXY',
  teacherPin: '2468',            // change this to your own number

  brand: {
    appName:   'JARVIS',
    teacher:   'Mr. Volz',   // what students see, e.g. 'Mr. Smith' or 'Ms. Lee'
    className: '',               // shown in the browser tab, e.g. 'Room 12'
    school:    '',
    tvName:    'School TV',      // only used if the tv module is on
    colors: { main: '#2E6FD0', dark: '#1F3A5F', light: '#A9C7F2' }
  },

  /* Grade levels your class uses. Leave empty [] to offer every level, kindergarten through college.
     Ids: 'K','1'..'8' (grades), '9','10','11','12' (freshman to senior), 'C1','C2','C3','C4' (college years).
     Examples:  ['7','8']   ['K','1','2']   ['9','10','11','12']   ['C1','C2','C3','C4'] */
  grades: [],

  /* Optional modules. true = on, false = off. */
  features: {
    weeklyReport: false,   // auto-assigned weekly report (needs checkins style prompts)
    checkins:     false,   // daily / midweek check-in prompts
    tv:           false,   // TV rundowns, announcements, segment library
    schoology:    false,   // Schoology sync log page
    abDays:       false,   // A/B day tags
    inspiration:  false,   // weekly Inspiration post
    startSlide:   false    // full-screen start-of-class slide
  }
};
